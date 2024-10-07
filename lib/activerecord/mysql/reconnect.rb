if RUBY_PLATFORM != 'java'
  require 'mysql2'
end
require 'logger'
require 'bigdecimal'

require 'active_record'
require 'active_record/connection_adapters/abstract_adapter'
require 'active_record/connection_adapters/abstract_mysql_adapter'
if RUBY_PLATFORM != 'java'
  require 'active_record/connection_adapters/mysql2_adapter'
else
  require 'active_record/connection_adapters/jdbc_adapter'
end
require 'active_record/connection_adapters/abstract/connection_pool'

require 'activerecord/mysql/reconnect/version'
require 'activerecord/mysql/reconnect/base_ext'
# XXX:
#require 'activerecord/mysql/reconnect/abstract_adapter_ext'
if RUBY_PLATFORM != 'java'
  require 'activerecord/mysql/reconnect/abstract_mysql_adapter_ext'
  require 'activerecord/mysql/reconnect/mysql2_adapter_ext'
else
  require 'activerecord/mysql/reconnect/jdbc_adapter_ext'
end
require 'activerecord/mysql/reconnect/connection_pool_ext'

module Activerecord::Mysql::Reconnect
  DEFAULT_EXECUTION_TRIES = 3
  DEFAULT_EXECUTION_RETRY_WAIT = 0.5

  WITHOUT_RETRY_KEY = 'activerecord-mysql-reconnect-without-retry'
  RETRYABLE_TRANSACTION_KEY = 'activerecord-mysql-reconnect-transaction-retry'

  if RUBY_PLATFORM != 'java'
    HANDLE_ERROR = [
      ActiveRecord::StatementInvalid,
      Mysql2::Error,
    ]
  else
    HANDLE_ERROR = [
      ActiveRecord::StatementInvalid,
      ActiveRecord::JDBCError,
    ]
  end

  HANDLE_R_ERROR_MESSAGES = [
    'Lost connection to MySQL server during query',
  ]

  HANDLE_RW_ERROR_MESSAGES = [
    'MySQL server has gone away',
    'Server shutdown in progress',
    'closed MySQL connection',
    "Can't connect to MySQL server",
    "Can't connect to local MySQL server", # When running in local sandbox, or using a socket file
    'Could not create connection to database server',
    'Query execution was interrupted',
    'Access denied for user',
    'The MySQL server is running with the --read-only option',
    'Unknown MySQL server host', # For DNS blips
    'Communications link failure',
    'Lost connection to MySQL server at',
    'SSL connection error', # RDS Proxy blips
    'The last transaction was aborted due to Zero Downtime Restart' # Aurora node restarts
  ]

  HANDLE_ERROR_MESSAGES = HANDLE_R_ERROR_MESSAGES + HANDLE_RW_ERROR_MESSAGES

  READ_SQL_REGEXP = /\A\s*(?:SELECT|SHOW|SET)\b/i

  RETRY_MODES = [:r, :rw, :force]
  DEFAULT_RETRY_MODE = :r

  class << self
    def execution_tries
      ActiveRecord::Base.execution_tries || DEFAULT_EXECUTION_TRIES
    end

    def execution_retry_wait
      wait = ActiveRecord::Base.execution_retry_wait || DEFAULT_EXECUTION_RETRY_WAIT
      wait.kind_of?(BigDecimal) ? wait : BigDecimal(wait.to_s)
    end

    def enable_retry
      !!ActiveRecord::Base.enable_retry
    end

    def retry_mode=(v)
      unless RETRY_MODES.include?(v)
        raise "Invalid retry_mode. Please set one of the following: #{RETRY_MODES.map {|i| i.inspect }.join(', ')}"
      end

      @activerecord_mysql_reconnect_retry_mode = v
    end

    def retry_mode
      @activerecord_mysql_reconnect_retry_mode || DEFAULT_RETRY_MODE
    end

    def retry_databases=(v)
      v ||= []

      unless v.kind_of?(Array)
        v = [v]
      end

      @activerecord_mysql_reconnect_retry_databases = v.map {|i| i.to_s }
    end

    def retry_databases
      @activerecord_mysql_reconnect_retry_databases || []
    end

    def error_callback
      @reconnect_error_callback ||= ->(e, n, wait, conn) do
        # conn_info = connection_info conn
        logger.error "[ATTEMPT #{n}] MySQL server has gone away. Trying to reconnect in #{wait} seconds. (#{e.class}: #{e.message})"
      end
    end

    def error_callback=(proc)
      @reconnect_error_callback = proc
    end

    def reconnect_callback
      @ar_reconnect_callback ||= -> do
        # logger.debug 'Establishing connection to database...'
      end
    end

    def reconnect_callback=(proc)
      @ar_reconnect_callback = proc
    end

    def retryable(opts)
      block     = opts.fetch(:proc)
      on_error  = opts[:on_error]
      conn      = opts[:connection]
      error_callback = opts[:error_callback]
      reconnect_callback = opts[:reconnect_callback]
      tries     = self.execution_tries
      retval    = nil

      retryable_loop(tries) do |n|
        begin
          reconnect_callback.call if reconnect_callback
          retval = block.call
          break
        rescue => e
          if enable_retry and (tries.zero? or n < tries) and should_handle?(e, opts)
            on_error.call if on_error
            wait = self.execution_retry_wait * n
            error_callback.call(e, n, wait, conn) if error_callback
            sleep(wait)
            next
          else
            raise e
          end
        end
      end

      return retval
    end

    def logger
      if defined?(Rails)
        Rails.logger || ActiveRecord::Base.logger || Logger.new($stderr)
      else
        ActiveRecord::Base.logger || Logger.new($stderr)
      end
    end

    def without_retry
      begin
        Thread.current[WITHOUT_RETRY_KEY] = true
        yield
      ensure
        Thread.current[WITHOUT_RETRY_KEY] = nil
      end
    end

    def without_retry?
      !!Thread.current[WITHOUT_RETRY_KEY]
    end

    def retryable_transaction
      begin
        Thread.current[RETRYABLE_TRANSACTION_KEY] = []

        ActiveRecord::Base.transaction do
          yield
        end
      ensure
        Thread.current[RETRYABLE_TRANSACTION_KEY] = nil
      end
    end

    def retryable_transaction_buffer
      Thread.current[RETRYABLE_TRANSACTION_KEY]
    end

    private

    def retryable_loop(n)
      if n.zero?
        loop { n += 1 ; yield(n) }
      else
        n.times {|i| yield(i + 1) }
      end
    end

    def should_handle?(e, opts = {})
      sql        = opts[:sql]
      retry_mode = opts[:retry_mode]
      conn       = opts[:connection]

      if without_retry?
        return false
      end

      if conn and not retry_databases.empty?
        conn_info = connection_info(conn)
        return false unless retry_databases.include?(conn_info[:database])
      end

      unless HANDLE_ERROR.any? {|i| e.kind_of?(i) }
        return false
      end

      unless Regexp.union(HANDLE_ERROR_MESSAGES) =~ e.message
        return false
      end

      if sql and READ_SQL_REGEXP !~ sql
        if retry_mode == :r
          return false
        end

        if retry_mode != :force and Regexp.union(HANDLE_R_ERROR_MESSAGES) =~ e.message
          return false
        end
      end

      return true
    end

    def connection_info(conn)
      conn_info = {}

      if RUBY_PLATFORM != 'java' && conn.kind_of?(Mysql2::Client)
        [:host, :database, :username].each {|k| conn_info[k] = conn.query_options[k] }
      elsif conn.kind_of?(Hash)
        conn_info = conn.dup
      end

      return conn_info
    end
  end # end of class methods
end
