require 'win32/registry'
require 'yaml'
require 'fileutils'

module DevKitInstaller

  DEVKIT_ROOT = File.expand_path(File.dirname(__FILE__))

  # TODO add JRuby installer registry key
  REG_KEYS = [
    'Software\RubyInstaller\MRI',
    'Software\RubyInstaller\Rubinius'
  ]

  STUB_CMDS = [
    'gcc',
    'g++',
    'make',
    'sh'
  ]

  CONFIG_FILE = 'config.yml'

  def self.usage
<<-EOT

Configures an MSYS/MinGW based Development Kit (DevKit) for
each of the Ruby installations on your Windows system. The
DevKit enables you to build many of the available native
C-based RubyGems that don't yet have a binary gem.

Usage: ruby dk.rb COMMAND

where COMMAND is one of:

  init     prepare DevKit for installation
  review   review DevKit install plan
  install  install required DevKit executables

EOT
  end

  def self.stub_for(cmd, dk_root=DEVKIT_ROOT)
<<-EOT
@ECHO OFF
SETLOCAL
SET DEVKIT=#{dk_root.gsub('/','\\')}
SET PATH=%DEVKIT%\\bin;%DEVKIT%\\mingw\\bin;%PATH%
#{cmd}.exe %*
EOT
  end
  private_class_method :stub_for

  def self.gem_override(dk_root=DEVKIT_ROOT)
    d = dk_root.gsub('/', '\\\\\\')
<<-EOT
# override 'gem install' to enable RubyInstaller DevKit usage
Gem.pre_install do |i|
  unless ENV['PATH'].include?('#{d}\\\\mingw\\\\bin') then
    puts 'Temporarily enhancing PATH to include DevKit...'
    ENV['PATH'] = '#{d}\\\\bin;#{d}\\\\mingw\\\\bin;' + ENV['PATH']
  end
end
EOT
  end
  private_class_method :gem_override

  def self.devkit_lib(dk_root=DEVKIT_ROOT)
    d = dk_root.gsub('/', '\\\\\\')
<<-EOT
# enable RubyInstaller DevKit usage as a vendorable helper library
unless ENV['PATH'].include?('#{d}\\\\mingw\\\\bin') then
  puts 'Temporarily enhancing PATH to include DevKit...'
  ENV['PATH'] = '#{d}\\\\bin;#{d}\\\\mingw\\\\bin;' + ENV['PATH']
end
EOT
  end
  private_class_method :devkit_lib

  def self.scan_for(key)
    ris = []
    [Win32::Registry::HKEY_LOCAL_MACHINE, Win32::Registry::HKEY_CURRENT_USER].each do |hive|
      begin
        hive.open(key) do |ri_key|
          ri_key.each_key do |skey, wtime|
            # read the install location if a version subkey
            if skey =~ /\d\.\d\.\d/
              ri_key.open(skey) do |ver_key|
                ris << ver_key['InstallLocation'].gsub('\\', '/')
              end
            end
          end
        end
      rescue Win32::Registry::Error => ex
        $stderr.puts '[INFO] unable to open %s\%s...' % [hive.keyname, key]
      end
    end
    ris
  end
  private_class_method :scan_for

  def self.installed_rubies
    rubies = REG_KEYS.collect { |key| scan_for(key) }
    rubies.flatten.uniq
  end
  private_class_method :installed_rubies

  def self.init
    # get all known installed Ruby root dirs and write the root dirs
    # to 'config.yml', overwriting any existing config file.
    ir = installed_rubies

    File.open(CONFIG_FILE, 'w') do |f|
      f.write <<-EOT
# This configuration file contains the absolute path locations of all
# installed Rubies to be enhanced to work with the DevKit. This config
# file is generated by the 'ruby dk.rb init' step and may be modified
# before running the 'ruby dk.rb install' step. To include any installed
# Rubies that were not automagically discovered, simply add a line below
# the triple hyphens with the absolute path to the Ruby root directory.
#
# Example:
#
# ---
# - C:/ruby19trunk
# - C:/ruby192dev
#
EOT
      f.write(ir.to_yaml)
    end
  end
  private_class_method :init

  def self.review
    if File.exists?(File.expand_path(CONFIG_FILE))
      File.open(CONFIG_FILE, 'r') do |f|
        puts <<-EOT
Based upon the settings in the '#{CONFIG_FILE}' file generated
from running 'ruby dk.rb init' and any of your customizations,
DevKit functionality will be injected into the following Rubies
when you run 'ruby dk.rb install'.

EOT
        puts YAML.load(f.read)
      end
    else
      puts <<-EOT
Unable to find '#{CONFIG_FILE}'.  Have you run 'ruby dk.rb init' yet?
EOT
    end
  end

  def self.install
    rubies = YAML.load_file(CONFIG_FILE)

    rubies.each do |path|
      unless File.directory?(File.expand_path(path))
        puts "[ERROR] Invalid directory '#{path}', skipping."
        next
      end

      site_ruby = Dir.glob("#{path}/lib/ruby/site_ruby")
      site_rubygems = Dir.glob("#{path}/lib/ruby/site_ruby/**/rubygems")
      core_rubygems = Dir.glob("#{path}/lib/ruby/**/rubygems")

      # inject stubs if RubyGems isn't in site_ruby or core ruby, making
      # backups of any existing stubs
      if site_rubygems.empty? && core_rubygems.empty?
        puts <<-EOT
Unable to find RubyGems in site_ruby or core Ruby. Falling back
to installing gcc, g++, make, and sh into #{path}
EOT
        STUB_CMDS.each do |command|
          target = File.join(path, 'bin', "#{command}.bat")

          if File.exist?(target)
            puts "Renaming #{command}.bat to #{command}.bat.orig"
            File.rename(target, "#{target}.orig")
          end

          File.open(target, 'w') do |f|
            f.write(stub_for(command))
          end
        end
      else
        # either (or both) site_rubygems or core_rubygems contains RubyGems;
        # favor injecting override into site_rubygems over core_rubygems
        target_ruby = site_rubygems.empty? ? core_rubygems : site_rubygems

        # inject RubyGems override file into proper site_ruby location
        # appending an existing override file
        target_ruby.each do |folder|
          target = File.join(folder, 'defaults', 'operating_system.rb')
          FileUtils.mkdir_p File.dirname(target)

          if File.exist?(target)
            content = File.read(target)
            unless content.include?('DevKit')
              puts '[INFO] Updating existing RubyGems override.'
              File.open(target, 'a') { |f| f.write(gem_override) }
            else
              puts "[INFO] RubyGems override already in place for #{path}, skipping."
            end
          else
            puts "[INFO] Installing #{target}"
            File.open(target, 'w') { |f| f.write(gem_override) }
          end
        end
      end

      # inject DevKit PATH helper into site_ruby (allows for overriding)
      # for the 'ruby -rdevkit extconf.rb' use case.
      # TODO more robust JRuby check since can't assume JRuby is running
      #      this script?
      jruby_site_shared = File.join(site_ruby, 'shared')
      if File.directory?(jruby_site_shared) && File.exist?(File.join(path, 'bin', 'jruby.bat'))
        site_ruby =  jruby_site_shared
      end

      target = File.join(site_ruby, 'devkit.rb')
      if File.exist?(target)
        # Be paranoid about our 'site_ruby/devkit.rb' namespace. Either
        # someone else has collided with it, or we've already written the
        # helper lib. Warn the developer and skip rather than overwriting
        # or appending.
        puts "[WARN] DevKit helper library already exists for #{path}, skipping."
      else
        puts "[INFO] Installing #{target}"
        File.open(target, 'w') { |f| f.write(devkit_lib) }
      end
    end
  end
  private_class_method :install

  def self.usage_and_exit
    $stderr.puts usage
    exit(-1)
  end

  def self.run(*args)
    send(args.first)
  end

end

if __FILE__ == $0
  DevKitInstaller.usage_and_exit if ARGV.empty?

  cmd = ARGV.delete('init') ||
        ARGV.delete('review') ||
        ARGV.delete('install')

  DevKitInstaller.usage_and_exit unless ARGV.empty?

  DevKitInstaller.run(cmd)
end
