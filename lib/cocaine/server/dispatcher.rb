require 'cocaine/asio/channel'
require 'cocaine/protocol'
require 'cocaine/server/health'
require 'cocaine/server/request'
require 'cocaine/server/response'


class Cocaine::WorkerDispatcher < Cocaine::Dispatcher
  def initialize(worker, conn)
    super conn
    @worker = worker
    @health = Cocaine::HealthManager.new self
    @health.start
    @channels = {}
  end

  def process(session, message)
    case message.id
      when RPC::HEARTBEAT
        @health.breath()
      when RPC::TERMINATE
        @worker.terminate message.errno, message.reason
      when RPC::INVOKE
        channel = Cocaine::Channel.new
        request = Cocaine::Request.new channel
        response = Cocaine::Response.new session, self
        @channels[session] = channel
        @worker.invoke(message.event, request, response)
      when RPC::CHUNK
        df = @channels[session]
        df.trigger message.data
      when RPC::ERROR
        df = @channels[session]
        df.error message.reason
      when RPC::CHOKE
        df = @channels.delete(session)
        df.close
      else
        raise "unexpected message id: #{id}"
    end
  end

  def send_handshake(session, uuid)
    send Handshake.new(uuid), session
  end

  def send_heartbeat(session)
    send Heartbeat.new, session
  end

  def send_terminate(session, errno, reason)
    send Terminate.new(errno, reason), session
  end

  def send_chunk(session, data)
    send Chunk.new(data), session
  end

  def send_error(session, errno, reason)
    send Error.new(errno, reason), session
  end

  def send_choke(session)
    send Choke.new, session
  end

  private
  def send(message, session)
    @conn.send_data message.pack(session)
  end
end