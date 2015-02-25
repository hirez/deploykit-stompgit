# Wombat

class UserLoginException<Exception;end;
class MissingRepoException<Exception;end;
class NotOurRepoException<Exception;end;

# Lifted wholesale from mcollective, with grovelling apologies to the relevant lovely
# people for bastardising their fine c0de.
class EventLogger
  def on_publish(params, message, headers)
    $log.debug("Published #{headers} to #{stomp_url(params)}")
  rescue
  end

  def on_connecting(params=nil)
    $log.info("TCP Connection attempt %d to %s" % [params[:cur_conattempts], stomp_url(params)])
  rescue
  end

  def on_connected(params=nil)
    $log.info("Connected to #{stomp_url(params)}")
  rescue
  end

  def on_disconnect(params=nil)
    $log.info("Disconnected from #{stomp_url(params)}")
  rescue
  end

  def on_connectfail(params=nil)
    $log.info("TCP Connection to #{stomp_url(params)} failed on attempt #{params[:cur_conattempts]}")
  rescue
  end

  def on_miscerr(params, errstr)
    $log.error("Unexpected error on connection #{stomp_url(params)}: #{errstr}")
  rescue
  end

  def on_ssl_connecting(params)
    $log.info("Estblishing SSL session with #{stomp_url(params)}")
  rescue
  end

  def on_ssl_connected(params)
    $log.info("SSL session established with #{stomp_url(params)}")
  rescue
  end

  def on_ssl_connectfail(params)
    $log.error("SSL session creation with #{stomp_url(params)} failed: #{params[:ssl_exception]}")
  end

  # Stomp 1.1+ - heart beat read (receive) failed.
  def on_hbread_fail(params, ticker_data)

    max_hbrlck_fails = 0
    max_hbread_fails = 2

    if ticker_data["lock_fail"]
      if max_hbrlck_fails == 0
      # failure is disabled
        $log.debug("Heartbeat failed to acquire readlock for '%s': %s" % [stomp_url(params), ticker_data.inspect])
      elsif ticker_data['lock_fail_count'] >= max_hbrlck_fails
      # we're about to force a disconnect
        $log.error("Heartbeat failed to acquire readlock for '%s': %s" % [stomp_url(params), ticker_data.inspect])
      else
        $log.warn("Heartbeat failed to acquire readlock for '%s': %s" % [stomp_url(params), ticker_data.inspect])
      end
    else
      if max_hbread_fails == 0
      # failure is disabled
        $log.debug("Heartbeat read failed from '%s': %s" % [stomp_url(params), ticker_data.inspect])
      elsif ticker_data['read_fail_count'] >= max_hbread_fails
      # we're about to force a reconnect
        $log.error("Heartbeat read failed from '%s': %s" % [stomp_url(params), ticker_data.inspect])
      else
        $log.warn("Heartbeat read failed from '%s': %s" % [stomp_url(params), ticker_data.inspect])
      end
    end
  rescue Exception => e
  end

  # Stomp 1.1+ - heart beat send (transmit) failed.
  def on_hbwrite_fail(params, ticker_data)
    $log.error("Heartbeat write failed from '%s': %s" % [stomp_url(params), ticker_data.inspect])
  rescue Exception => e
  end

  # Log heart beat fires
  def on_hbfire(params, srind, curt)
    case srind
      when "receive_fire"
        $log.debug("Received heartbeat from %s: %s, %s" % [stomp_url(params), srind, curt])
      when "send_fire"
        $log.debug("Publishing heartbeat to %s: %s, %s" % [stomp_url(params), srind, curt])
    end
  rescue Exception => e
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
    if @type == "stderr"
      @log.error(message)
    elsif @type == "stdout"
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

  def initialize(stompmsg)
    @branch = ''
    @commit_id = ''
    @repo = ''

    @subj = stompmsg.headers["subject"]

    s1,s2,s3 = stompmsg.headers["subject"].split(' ',3)
    if s2 =~ /refs\/heads\//
      @branch = s2.sub('refs/heads/','')
      @commit_id = s3
    end

    stompmsg.body.lines do |mline|
      mkey,mval = mline.split(":",2)
      @repo = mval.strip if mkey == "repo"
    end
  end
end

def check_valid_user(user)
  guserinfo = Etc.getpwnam(user)
  if File.readlines('/etc/shells').grep(/#{guserinfo.shell}/).size == 0
    raise UserLoginException, "#{user} has no login shell."
  end
end

def check_valid_repo(msg_repo,conf_repos)
  raise NotOurRepoException, "Not our repo: #{msg_repo}" if !conf_repos[msg_repo]
  raise MissingRepoException, "Repo #{msg_repo} in config but not in filesystem." if !File.exists?(conf_repos[msg_repo]['repo'])
end

def gitfetch(mess,rdir,user)
  commandline = "/bin/su - #{user} -c \"cd #{rdir} && /usr/bin/git fetch && /usr/bin/git fetch --tags\""
  status,stdout,stderr = systemu(commandline, :cwd => rdir, :chomp => true)
  if status != 0
    status_message = "problem: " + stderr
  else
    status_message = "fetched change: #{mess.subj}"
  end
  return status_message
end

def git_branch(rdir,user,target,branch,repo)
  if !File.exists?(target)
    guserinfo = Etc.getpwnam(user)
    FileUtils.mkdir_p(target)
    File.chown(guserinfo.uid,guserinfo.gid,target)
  end
  commandline = "/bin/su - #{user} -c \"cd #{rdir} && /usr/bin/git --work-tree=#{target} checkout -f origin/#{branch}\""
  status,stdout,stderr = systemu(commandline, :cwd => rdir, :chomp => true)
  if status != 0
    status_message = "problem: " + stderr
  else
    status_message = "checked out: [#{repo}] #{branch} to #{target}"
  end
  return status_message
end

def git_puppetmaster(rdir,user,smsg,target,separator)
  pdir = target.to_s + separator + smsg.branch

  if smsg.commit_id =~ /0000000000000000000000000000000000000000/
    # forcefully remove the branch
    commandline = "/bin/su - #{user} -c \"/bin/rm -fr #{pdir}\""
    status,stdout,stderr = systemu(commandline, :chomp => true)
    if status != 0
      status_message = "problem removing branch: " + stderr
    else
      status_message = "removed branch #{pdir} "
    end
  else
    if !File.exists?(pdir)
      guserinfo = Etc.getpwnam(user)
      FileUtils.mkdir_p(pdir)
      File.chown(guserinfo.uid,guserinfo.gid,pdir)
    end
    commandline = "/bin/su - #{user} -c \"cd #{rdir} && /usr/bin/git --work-tree=#{pdir} checkout -f origin/#{smsg.branch}\""
    status,stdout,stderr = systemu(commandline, :cwd => rdir, :chomp => true)
    if status != 0
      status_message = "problem: " + stderr
    else
      status_message = "checked out #{smsg.branch} to #{target} as #{pdir}."
    end
  end

  return status_message
end

def logmessage(message,sclient,topic,debug)

  $log.info(message)

  host_name = Socket::gethostname
  smessage = host_name + " " + message
  begin
    sclient.publish("/topic/#{topic}",smessage, {:subject => "Talking to eventbot"})
  rescue Exception => e
    emessage = "Exception: #{e}"
    $log.error(emessage)
    puts emessage if debug
  end
  puts message if debug
end

def dumpmessage(message)
  puts "Subject: #{message.headers["subject"]}"
  puts "Message-ID: #{message.headers["message-id"]}"
  puts "--"
  puts message.body
  puts "--"
end

