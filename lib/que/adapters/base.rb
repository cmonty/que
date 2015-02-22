require 'time' # For Time.parse.

module Que
  module Adapters
    autoload :ActiveRecord,   'que/adapters/active_record'
    autoload :ConnectionPool, 'que/adapters/connection_pool'
    autoload :PG,             'que/adapters/pg'
    autoload :Pond,           'que/adapters/pond'
    autoload :Sequel,         'que/adapters/sequel'

    class Base
      def initialize(thing = nil)
        @prepared_statements = {}
      end

      # The only method that adapters really need to implement. Should lock a
      # PG::Connection (or something that acts like a PG::Connection) so that
      # no other threads are using it and yield it to the block. Should also
      # be re-entrant.
      def checkout(&block)
        raise NotImplementedError
      end

      # Called after a job is queued in async mode, to prompt a worker to
      # wake up after the current transaction commits. Not all adapters will
      # implement this.
      def wake_worker_after_commit
        false
      end

      def execute(command, params = [])
        params = params.map do |param|
          case param
            # The pg gem unfortunately doesn't convert fractions of time instances, so cast them to a string.
            when Time then param.strftime("%Y-%m-%d %H:%M:%S.%6N %z")
            when Array, Hash then JSON_MODULE.dump(param)
            else param
          end
        end

        cast_result \
          case command
            when Symbol then execute_prepared(command, params)
            when String then execute_sql(command, params)
          end
      end

      def in_transaction?
        checkout { |conn| conn.transaction_status != ::PG::PQTRANS_IDLE }
      end

      private

      def execute_sql(sql, params)
        args = params.empty? ? [sql] : [sql, params]
        checkout { |conn| conn.async_exec(*args) }
      end

      def execute_prepared(name, params)
        checkout do |conn|
          # Prepared statement errors have the potential to foul up the entire
          # transaction, so if we're in one, err on the side of safety.
          return execute_sql(SQL[name], params) if in_transaction?

          statements = @prepared_statements[conn] ||= {}

          begin
            unless statements[name]
              conn.prepare("que_#{name}", SQL[name])
              prepared_just_now = statements[name] = true
            end

            conn.exec_prepared("que_#{name}", params)
          rescue ::PG::InvalidSqlStatementName => error
            # Reconnections on ActiveRecord can cause the same connection
            # objects to refer to new backends, so recover as well as we can.

            unless prepared_just_now
              Que.log :level => 'warn', :event => "reprepare_statement", :name => name
              statements[name] = false
              retry
            end

            raise error
          end
        end
      end

      HASH_DEFAULT_PROC = proc { |hash, key| hash[key.to_s] if Symbol === key }

      INDIFFERENTIATOR = proc do |object|
        case object
        when Array
          object.each(&INDIFFERENTIATOR)
        when Hash
          object.default_proc = HASH_DEFAULT_PROC
          object.each { |key, value| object[key] = INDIFFERENTIATOR.call(value) }
          object
        else
          object
        end
      end

      CAST_PROCS = {}

      # Integer, bigint, smallint:
      CAST_PROCS[23] = CAST_PROCS[20] = CAST_PROCS[21] = proc(&:to_i)

      # Timestamp with time zone.
      CAST_PROCS[1184] = Time.method(:parse)

      # JSON.
      CAST_PROCS[114] = JSON_MODULE.method(:load)
      CAST_PROCS["args"] = CAST_PROCS[114]

      # Boolean:
      CAST_PROCS[16] = 't'.method(:==)

      def cast_result(result)
        output = result.to_a

        result.fields.each_with_index do |field, index|
          converter = CAST_PROCS[field] || CAST_PROCS[result.ftype(index)]
          if converter
            output.each do |hash|
              unless (value = hash[field]).nil?
                hash[field] = converter.call(value)
              end
            end
          end
        end

        if result.first.respond_to?(:with_indifferent_access)
          output.map(&:with_indifferent_access)
        else
          output.each(&INDIFFERENTIATOR)
        end
      end
    end
  end
end
