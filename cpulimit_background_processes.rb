require 'logger'
require 'yaml'
require 'optparse'

$logger = Logger.new $stdout
$logger.level = Logger::INFO
$foreground_pid = nil

ARGV << '-h' if ARGV.empty?

OptionParser.new do |opts|
  opts.banner = "Usage: #{File.basename $0} [options]"

  opts.on("-c", "--config PATH", "Config file path") do |path|
    $config = YAML.load_file path
  end

  opts.on_tail("-h", "--help", "Show this message") do
    puts opts
    exit
  end
end.parse!

def all_processes
  # res = `ps -fxo pid,comm | awk '$2 ~ /_/ { print $1, $3 }'`
  res = `ps -xo pid,comm`.downcase
  res.lines.map { |line| line.scan(/\S+/) }
end

def foreground_process
  # xdotool getwindowfocus  Alternatively:
  # xprop -root -notype | sed -n '/^_NET_ACTIVE_WINDOW/ s/^.*# *\|\,.*$//g p'
  active_window_id = 'xprop -root -f _NET_ACTIVE_WINDOW 0x " \$0\\n" _NET_ACTIVE_WINDOW | awk "{print \$2}"'
  active_window_pid = 'xprop -id $(' << active_window_id << ') -f _NET_WM_PID 0c " \$0\\n" _NET_WM_PID | awk "{print \$2}"'
  command = "ps -o pid,comm $(#{active_window_pid})"
  # command = 'ps -o pid,comm $(xprop -id $(xdotool getwindowfocus) -f _NET_WM_PID 0c " \$0\\n" _NET_WM_PID | cut -d" " -f2)'
  `#{ command }`.lines.last.downcase.scan(/\S+/)
end

def cpulimitted_pids
  res = `pgrep -a cpulimit`
  res.lines.map { |line| line.scan(/\d+/) }
end

def main
  fpid, fpname = foreground_process

  return if fpid == $foreground_pid
  $foreground_pid = fpid

  cpulimitted_pids = cpulimitted_pids()

  $logger.info "Foreground app: #{fpname} (PID=#{fpid})"

  all_processes.each do |pid, pname|
    if config = $config['processes'][pname]
      $logger.debug "Analyzing #{pid} #{pname}"
      #$config['processes'][pname] = false if config == :multi

      if pid == fpid || config == 'multi' && fpname == pname
        unlimit_cpu pname, pid, cpulimitted_pids
      else
        limit_cpu pname, pid, cpulimitted_pids
      end
    end
  end
end

def limit_cpu pname, pid, cpulimitted_pids
  return if cpulimitted_pids.any? { |cpulimit_pid, throttled_pid| throttled_pid == pid }

  $logger.info "Limiting CPU for #{pname} (PID=#{pid})."

  Thread.new do
    `renice 7 #{pid} && cpulimit -p #{pid} -l 1 -z -b &`
  end
end

def unlimit_cpu pname, pid, cpulimitted_pids
  cpulimitted_pids.each do |cpulimit_pid, throttled_pid|
    if throttled_pid[pid]
      $logger.info "Unlimiting CPU for #{pname} (PID=#{throttled_pid})."
      `kill #{cpulimit_pid}`
    end
  end
end

loop do
  main()
  sleep $config['poll_every']
end
