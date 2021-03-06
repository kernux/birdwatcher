module Birdwatcher
  class Console
    include Singleton

    DEFAULT_AUTO_COMPLETION_STRINGS = [].freeze
    DB_MIGRATIONS_PATH = File.expand_path("../../../db/migrations", __FILE__).freeze
    LINE_SEPARATOR = ("=" * 80).freeze

    attr_accessor :current_workspace, :current_module
    attr_reader :database

    def initialize
      @output_mutex = Mutex.new
    end

    def start!
      print_banner
      bootstrap!
      Readline.completion_proc = proc do |s|
        expanded_s = File.expand_path(s)
        Birdwatcher::Console.instance.auto_completion_strings.grep(/\A#{Regexp.escape(s)}/) + Dir["#{expanded_s}*"].grep(/^#{Regexp.escape(expanded_s)}/)
      end
      Readline.completion_append_character = ""
      while input = Readline.readline(prompt_line, true)
        input = input.to_s.strip
        handle_input(input) unless input.empty?
      end
    end

    def handle_input(input)
      input.strip!
      command_name, argument_line = input.split(" ", 2).map(&:strip)
      command_name.downcase
      commands.each do |command|
        next unless command.has_name?(command_name)
        command.new.execute(argument_line)
        return true
      end
      error("Unknown command: #{command_name.bold}")
      false
    end

    def auto_completion_strings
      if !@auto_completion_strings
        @auto_completion_strings = DEFAULT_AUTO_COMPLETION_STRINGS
        commands.each { |c| @auto_completion_strings += c.auto_completion_strings }
        @auto_completion_strings += Birdwatcher::Module.module_paths
      end
      @auto_completion_strings
    end

    def output(data, newline = true)
      data = "#{data}\n" if newline
      with_output_mutex { print data }
    end

    def output_formatted(*args)
      with_output_mutex { printf(*args) }
    end

    def newline
      with_output_mutex { puts }
    end

    def line_separator
      output LINE_SEPARATOR
    end

    def info(message)
      output "[+] ".bold.light_blue + message
    end

    def task(message, fatal = false, &block)
      output("[+] ".bold.light_blue + message, false)
      yield block
      output " done".bold.light_green
    rescue => e
      output " failed".bold.light_red
      error "#{e.class}: ".bold + e.message
      exit(1) if fatal
    end

    def error(message)
      output "[-] ".bold.light_red + message
    end

    def warn(message)
      output "[!] ".bold.light_yellow + message
    end

    def fatal(message)
      output "[-]".white.bold.on_red + " #{message}"
    end

    def twitter_client
      if !@twitter_clients
        @twitter_clients = create_twitter_clients!
      end
      @twitter_clients.sample
    end

    def klout_client
      if !@klout_clients
        @klout_clients = create_klout_clients!
      end
      @klout_clients.sample
    end

    private

    def print_banner
      output " ___ _        _             _      _\n" \
             "| _ |_)_ _ __| |_ __ ____ _| |_ __| |_  ___ _ _\n" \
             "| _ \\ | '_/ _` \\ V  V / _` |  _/ _| ' \\/ -_) '_|\n" \
             "|___/_|_| \\__,_|\\_/\\_/\\__,_|\\__\\__|_||_\\___|_|\n".bold.light_blue +
             "                       v#{Birdwatcher::VERSION} by " + "@michenriksen\n".bold
    end

    def bootstrap!
      bootstrap_configuration!
      bootstrap_database!
      newline
    end

    def bootstrap_configuration!
      if !Birdwatcher::Configuration.configured?
        Birdwatcher::ConfigurationWizard.new.start!
      end
      task "Loading configuration...", true do
        Birdwatcher::Configuration.load!
      end
    end

    def bootstrap_database!
      task "Preparing database...", true do
        Sequel.extension :migration, :core_extensions
        @database = Sequel.connect(configuration.get!(:database_connection_uri))
        Sequel::Migrator.run(@database, DB_MIGRATIONS_PATH)
        Sequel::Model.db = @database
        Sequel::Model.plugin :timestamps
        bootstrap_models!
        load_default_workspace!
      end
    end

    def bootstrap_models!
      Dir[File.join(File.dirname(__FILE__), "..", "..", "models", "*.rb")].each do |file|
        require file
      end
    end

    def prompt_line
      prompt = "birdwatcher[".bold + "#{current_workspace.name}" + "]".bold
      if current_module
        prompt += "[".bold + current_module.path.light_red + "]> ".bold
      else
        prompt += "> ".bold
      end
      prompt
    end

    def load_default_workspace!
      @current_workspace = Birdwatcher::Models::Workspace.find_or_create(
        :name => Birdwatcher::Models::Workspace::DEFAULT_WORKSPACE_NAME
      ) do |w|
        w.description = Birdwatcher::Models::Workspace::DEFAULT_WORKSPACE_DESCRIPTION
      end
    end

    def commands
      @commands ||= Birdwatcher::Command.descendants
    end

    def configuration
      Birdwatcher::Configuration
    end

    def with_output_mutex
      @output_mutex.synchronize { yield }
    end

    def create_twitter_clients!
      clients = []
      configuration.get!(:twitter).each do |keypair|
        clients << Twitter::REST::Client.new do |config|
          config.consumer_key    = keypair["consumer_key"]
          config.consumer_secret = keypair["consumer_secret"]
        end
      end
      clients
    end

    def create_klout_clients!
      clients = []
      configuration.get(:klout).each do |key|
        clients << Birdwatcher::KloutClient.new(key)
      end
      clients
    end
  end
end
