class HexCrawlProducer < Producer

  def initialize msg
    connection = get_connection
    connection.start

    channel = connection.create_channel
    queue   = channel.queue("hex_crawl", :durable => true)

    queue.publish(msg, :persistent => true)

    multi_log " [x] HexCrawlProducer sent #{msg}"

    connection.close
  rescue => e
    log.error e.message
    log.error e.backtrace.join("\n")
  end

end
