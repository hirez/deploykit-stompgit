# Wombat

require 'fluent-logger'
require 'yaml'
require 'socket'
require 'stomp'
require 'json'
require 'securerandom'
require 'systemu'
require 'fileutils'
require 'etc'



class UserLoginException<Exception;end;
class MissingRepoException<Exception;end;
class NotOurRepoException<Exception;end;


class GLog
  def initialize(config,debug)
    @conf = YAML.load_file(config)
    @logfile = Logger.new(@conf['log-file'])
    @debug = debug
    @rtopic = @conf['report-topic']
    @fname = @conf['fluent-name']

    if @rtopic
      @sconnector = @conf['stompconnector']
      @sconnector[:logger] = self
      @sclient = Stomp::Client.new(@sconnector)
    else
      @sclient = nil
    end

    if @debug
      @logfile.level = Logger::DEBUG
    else
      @logfile.level = Logger::INFO
      $stderr = Logwrite.new(@logfile, 'stderr')
      $stdout = Logwrite.new(@logfile, 'stdout')
    end

    if @fname
      @flog = Fluent::Logger::FluentLogger.new(@fname, :host=>'localhost', :port=>24224)
    end
  end

  def msg(message)
    @logfile.info(message)

    host_name = Socket::gethostname
    smessage = host_name + ' ' + message
    begin
      @sclient.publish("/topic/#{@rtopic}",smessage, {:subject => 'Talking to eventbot'}) if @sclient
      @flog.post('msg',{'message' => message}) if @flog
      puts message if @debug
    rescue Exception => e
      emessage = "Exception: #{e}"
      @logfile.error(emessage)
      puts emessage if @debug
    end
  end

  def hash(tag,hash)
    begin
      @flog.post(tag,hash) if @flog
      msg = tag + ': ' + hash.inspect
      @logfile.info(msg)
      if @sclient
        host_name = Socket::gethostname
        smsg = host_name + ' ' + msg
        @sclient.publish("/topic/#{@rtopic}",smsg, {:subject => 'Talking to eventbot'})
      end
      puts msg if @debug
    rescue Exception => e
      emessage = "Exception: #{e}"
      @logfile.error(emessage)
      puts emessage if @debug
    end
  end

  def on_publish(params, message, headers)
    @logfile.debug("Published #{headers} to #{stomp_url(params)}")
  rescue
  end

  def on_connecting(params=nil)
    @logfile.info("TCP Connection attempt %d to %s" % [params[:cur_conattempts], stomp_url(params)])
  rescue
  end

  def on_connected(params=nil)
    @logfile.info("Connected to #{stomp_url(params)}")
  rescue
  end

  def on_disconnect(params=nil)
    @logfile.info("Disconnected from #{stomp_url(params)}")
  rescue
  end

  def on_connectfail(params=nil)
    @logfile.info("TCP Connection to #{stomp_url(params)} failed on attempt #{params[:cur_conattempts]}")
  rescue
  end

  def on_miscerr(params, errstr)
    @logfile.error("Unexpected error on connection #{stomp_url(params)}: #{errstr}")
  rescue
  end

  def on_ssl_connecting(params)
    @logfile.info("Estblishing SSL session with #{stomp_url(params)}")
  rescue
  end

  def on_ssl_connected(params)
    @logfile.info("SSL session established with #{stomp_url(params)}")
  rescue
  end

  def on_ssl_connectfail(params)
    @logfile.error("SSL session creation with #{stomp_url(params)} failed: #{params[:ssl_exception]}")
  end

  # Stomp 1.1+ - heart beat read (receive) failed.
  def on_hbread_fail(params, ticker_data)

    max_hbrlck_fails = 0
    max_hbread_fails = 2

    if ticker_data["lock_fail"]
      if max_hbrlck_fails == 0
      # failure is disabled
        @logfile.debug("Heartbeat failed to acquire readlock for '%s': %s" % [stomp_url(params), ticker_data.inspect])
      elsif ticker_data['lock_fail_count'] >= max_hbrlck_fails
      # we're about to force a disconnect
        @logfile.error("Heartbeat failed to acquire readlock for '%s': %s" % [stomp_url(params), ticker_data.inspect])
      else
        @logfile.warn("Heartbeat failed to acquire readlock for '%s': %s" % [stomp_url(params), ticker_data.inspect])
      end
    else
      if max_hbread_fails == 0
      # failure is disabled
        @logfile.debug("Heartbeat read failed from '%s': %s" % [stomp_url(params), ticker_data.inspect])
      elsif ticker_data['read_fail_count'] >= max_hbread_fails
      # we're about to force a reconnect
        @logfile.error("Heartbeat read failed from '%s': %s" % [stomp_url(params), ticker_data.inspect])
      else
        @logfile.warn("Heartbeat read failed from '%s': %s" % [stomp_url(params), ticker_data.inspect])
      end
    end
  rescue Exception
  end

  # Stomp 1.1+ - heart beat send (transmit) failed.
  def on_hbwrite_fail(params, ticker_data)
    @logfile.error("Heartbeat write failed from '%s': %s" % [stomp_url(params), ticker_data.inspect])
  rescue Exception
  end

  # Log heart beat fires
  def on_hbfire(params, srind, curt)
    case srind
      when "receive_fire"
        @logfile.debug("Received heartbeat from %s: %s, %s" % [stomp_url(params), srind, curt])
      when "send_fire"
        @logfile.debug("Publishing heartbeat to %s: %s, %s" % [stomp_url(params), srind, curt])
    end
  rescue Exception
  end

  def stomp_url(params)
    "%s://%s@%s:%d" % [ params[:cur_ssl] ? "stomp+ssl" : "stomp", params[:cur_login], params[:cur_host], params[:cur_port]]
  end
end

# stdout and stderr require an io handle to write to... this makes Logger one :)
class Logwrite
  def initialize(logger, type)
    @log = logger
    @type = type
  end

  def write(message)
    if @type == 'stderr'
      @log.error(message)
    elsif @type == 'stdout'
      @log.info(message)
    end
    return message.to_s.bytesize
  end

  # Dummy method to keep what passes for the standard i/o library happy.
  def flush
    #
  end

  alias puts write
  alias print write
  alias p write
end

class Parsemessage
  attr_reader :repo
  attr_reader :subj
  attr_reader :branch
  attr_reader :commit_id
  attr_reader :mjson
  attr_reader :uuid

  def initialize(stompmsg)
    @branch = ''
    @commit_id = ''
    @repo = ''
    @mjson = ''

    @uuid = SecureRandom.uuid
    @subj = stompmsg.headers['subject']

    _s1,s2,s3 = stompmsg.headers['subject'].split(' ',3)
    if s2 =~ /refs\/heads\//
      @branch = s2.sub('refs/heads/','')
      @commit_id = s3
    end

    stompmsg.body.lines do |mline|
      mkey,mval = mline.split(':',2)
      @repo  = mval.strip if mkey == 'repo'
      @mjson = JSON.parse(mval.strip) if mkey == 'JSON'
    end
  end
end

def check_valid_user(user)
  guserinfo = Etc.getpwnam(user)
  if File.readlines('/etc/shells').grep(/#{guserinfo.shell}/).size == 0
    raise UserLoginException
  end
end

def check_valid_repo(msg_repo,conf_repos)
  raise NotOurRepoException if !conf_repos[msg_repo]
  raise MissingRepoException if !File.exists?(conf_repos[msg_repo]['repo'])
end

def genstatus(ms)
  gs = {}
  @repo_bits = ms.mjson['repository']
  gs['uuid'] = ms.uuid
  gs['oldrev'] = ms.mjson['before']
  gs['newrev'] = ms.mjson['after']
  gs['user'] = ms.mjson['user_name']
  gs['ref'] = ms.mjson['ref']
  gs['repo'] = @repo_bits['name']
  return gs
end

def gitfetch(mess,rdir,user)
  status = genstatus(mess)

  @commandline = "/bin/su - #{user} -c \"cd #{rdir} && /usr/bin/git fetch && /usr/bin/git fetch --tags\""
  @result,@stdout,@stderr = systemu(@commandline, :cwd => rdir, :chomp => true)

  if @result != 0
    status['status'] = 'problem'
    status['error'] = @stderr.strip
  else
    status['status'] = 'fetch ok.'
  end
  return status
end

def git_branch(mess,rdir,user,target,branch)
  if !File.exists?(target)
    guserinfo = Etc.getpwnam(user)
    FileUtils.mkdir_p(target)
    File.chown(guserinfo.uid,guserinfo.gid,target)
  end

  @commandline = "/bin/su - #{user} -c \"cd #{rdir} && /usr/bin/git --work-tree=#{target} checkout -f origin/#{branch}\""
  @result,@stdout,@stderr = systemu(@commandline, :cwd => rdir, :chomp => true)
  status = genstatus(mess)

  if @result != 0
    status['status'] = 'problem'
    status['error'] = @stderr.strip
  else
    status['status'] = 'checkout ok.'
    status['target'] = target
  end
  return status
end

def git_puppetmaster(rdir,user,smsg,target,separator)
  @pdir = target.to_s + separator + smsg.branch
  status = genstatus(smsg)

  if smsg.commit_id =~ /0000000000000000000000000000000000000000/
    # forcefully remove the branch
    @commandline = "/bin/su - #{user} -c \"/bin/rm -fr #{@pdir}\""
    @result,@stdout,@stderr = systemu(@commandline, :chomp => true)

    if @result != 0
      status['status'] = 'problem'
      status['error'] = @stderr.strip
    else
      status['status'] = "removed branch #{@pdir}"
    end
  else
    unless File.exists?(@pdir)
      guserinfo = Etc.getpwnam(user)
      FileUtils.mkdir_p(@pdir)
      File.chown(guserinfo.uid,guserinfo.gid,@pdir)
    end
    @commandline = "/bin/su - #{user} -c \"cd #{rdir} && /usr/bin/git --work-tree=#{@pdir} checkout -f origin/#{smsg.branch}\""
    @result,@stdout,@stderr = systemu(@commandline, :cwd => rdir, :chomp => true)
    if @result != 0
      status['status'] = 'problem'
      status['error'] = @stderr.strip
    else
      status['status'] = 'checkout ok'
      status['target'] = @pdir
    end
  end

  return status
end

def git_tags(rdir,user,smsg,target,separator)
  @pdir = target.to_s + separator + smsg.tag
  status = genstatus(smsg)

  if smsg.commit_id =~ /0000000000000000000000000000000000000000/
    # forcefully remove the branch
    @commandline = "/bin/su - #{user} -c \"/bin/rm -fr #{@pdir}\""
    @result,@stdout,@stderr = systemu(@commandline, :chomp => true)
    if @result  != 0
      status['status'] = 'problem'
      status['error'] =  @stderr.strip
    else
      status['status'] = "removed tag #{@pdir}"
    end
  else
    unless File.exists?(@pdir)
      guserinfo = Etc.getpwnam(user)
      FileUtils.mkdir_p(@pdir)
      File.chown(guserinfo.uid,guserinfo.gid,@pdir)
    end
    @commandline = "/bin/su - #{user} -c \"cd #{rdir} && /usr/bin/git --work-tree=#{@pdir} checkout -f origin/#{smsg.tag}\""
    @result,@stdout,@stderr = systemu(@commandline, :cwd => rdir, :chomp => true)
    if @result != 0
      status['status'] = 'problem'
      status['error'] = @stderr.strip
    else
      status['status'] = 'checkout ok'
      status['target'] = @pdir
    end
  end

  return status
end

def dumpmessage(message)
  puts "Subject: #{message.headers['subject']}"
  puts "Message-ID: #{message.headers['message-id']}"
  puts '--'
  puts message.body
  puts '--'
end

