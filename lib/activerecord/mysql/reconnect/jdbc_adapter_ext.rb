class ActiveRecord::ConnectionAdapters::JdbcAdapter
  def reconnect_with_retry!
    Activerecord::Mysql::Reconnect.retryable(
      :proc => proc {
        reconnect_without_retry!
      },
      :connection => @connection,
      :reconnect_callback => Activerecord::Mysql::Reconnect.reconnect_callback
    )
  end

  alias_method_chain :reconnect!, :retry

  def execute_with_reconnect(sql, name = nil, binds = nil)
    retryable(sql, name, binds) do |sql_names|
      retval = nil

      sql_names.each do |s, n, b|
        retval = execute_without_reconnect(s, n, b)
      end

      add_sql_to_transaction(sql, name, binds)
      retval
    end
  end

  alias_method_chain :execute, :reconnect

  def exec_query_raw_with_reconnect(sql, name = 'SQL', binds = [])
    retryable(sql, name, binds) do |sql_names|
      retval = nil

      sql_names.each do |s, n, b|
        retval = execute_without_reconnect(s, n, b)
      end

      add_sql_to_transaction(sql, name, binds)
      retval
    end
  end

  alias_method_chain :exec_query_raw, :reconnect

  private

  def retryable(sql, name, binds = nil, &block)
    block_with_reconnect = nil
    sql_names = [[sql, name, binds]]
    orig_transaction = @transaction

    Activerecord::Mysql::Reconnect.retryable(
        :proc => proc {
          (block_with_reconnect || block).call(sql_names)
        },
        :on_error => proc {
          unless block_with_reconnect
            block_with_reconnect = proc do |i|
              reconnect_without_retry!
              @transaction = orig_transaction if orig_transaction
              block.call(i)
            end
          end

          sql_names = merge_transaction(sql, name, binds)
        },
        :sql => sql,
        :retry_mode => Activerecord::Mysql::Reconnect.retry_mode,
        :connection => @connection,
        :error_callback => Activerecord::Mysql::Reconnect.error_callback
    )
  end

  def add_sql_to_transaction(sql, name, binds = nil)
    if (buf = Activerecord::Mysql::Reconnect.retryable_transaction_buffer)
      buf << [sql, name, binds]
    end
  end

  def merge_transaction(sql, name, binds = nil)
    sql_name = [sql, name, binds]

    if (buf = Activerecord::Mysql::Reconnect.retryable_transaction_buffer)
      buf + [sql_name, binds]
    else
      [sql_name]
    end
  end
end
