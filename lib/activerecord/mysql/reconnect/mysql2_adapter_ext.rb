class ActiveRecord::ConnectionAdapters::Mysql2Adapter
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
end
