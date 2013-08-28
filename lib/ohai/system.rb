#
# Author:: Adam Jacob (<adam@opscode.com>)
# Copyright:: Copyright (c) 2008 Opscode, Inc.
# License:: Apache License, Version 2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require 'ohai/loader'
require 'ohai/log'
require 'ohai/mash'
require 'ohai/os'
require 'ohai/dsl/plugin'
require 'ohai/mixin/from_file'
require 'ohai/mixin/command'
require 'ohai/mixin/string'
require 'mixlib/shellout'

require 'yajl'

module Ohai
  
  class NoAttributeError < Exception
  end

  class DependencyCycleError < Exception
  end

  class System
    attr_accessor :data
    attr_reader :attributes
    attr_reader :hints
    attr_reader :v6_dependency_solver

    def initialize
      @data = Mash.new
      @attributes = Mash.new
      @hints = Hash.new
      @v6_dependency_solver = Hash.new
      @plugin_path = ""
    end

    def [](key)
      @data[key]
    end

    def load_plugins
      loader = Ohai::Loader.new(self)

      Ohai::Config[:plugin_path].each do |path|
        [
         Dir[File.join(path, '*')],
         Dir[File.join(path, Ohai::OS.collect_os, '**', '*')]
        ].flatten.each do |file|
          file_regex = Regexp.new("#{File.expand_path(path)}#{File::SEPARATOR}(.+).rb$")
          md = file_regex.match(file)
          if md
            plugin_path = md[0]
            unless @v6_dependency_solver.has_key?(plugin_path)
              plugin = loader.load_plugin(plugin_path)
              @v6_dependency_solver[plugin_path] = plugin unless plugin.nil?
            else
              Ohai::Log.debug("Already loaded plugin at #{plugin_path}")
            end
          end
        end
      end
    end

    # @note: assumes only two levels of attribute definition in
    # provides and depends
    def run_plugins(safe = false)
      @attributes.keys.each do |attribute|
        attrs = @attributes[attribute]
        attrs.keys.each do |attr|
          run_providers(attrs[attr][:providers], safe) unless attr.eql?('providers')
        end

        run_providers(attrs[:providers], safe) if attrs[:providers]
      end
    end
    
    def all_plugins
      require_plugin('os')

      Ohai::Config[:plugin_path].each do |path|
        [
          Dir[File.join(path, '*')],
          Dir[File.join(path, @data[:os], '**', '*')]
        ].flatten.each do |file|
          file_regex = Regexp.new("#{File.expand_path(path)}#{File::SEPARATOR}(.+).rb$")
          md = file_regex.match(file)
          if md
            plugin_name = md[1].gsub(File::SEPARATOR, "::")
            require_plugin(plugin_name) unless @seen_plugins.has_key?(plugin_name)
          end
        end
      end
      unless RUBY_PLATFORM =~ /mswin|mingw32|windows/
        # Catch any errant children who need to be reaped
        begin
          true while Process.wait(-1, Process::WNOHANG)
        rescue Errno::ECHILD
        end
      end
      true
    end

    def collect_providers(providers)
      refreshments = []
      if providers.is_a?(Mash)
        providers.keys.each do |provider|
          if provider.eql?("_providers")
            refreshments << providers[provider]
          else
            refreshments << collect_providers(providers[provider])
          end
        end
      else
        refreshments << providers
      end
      refreshments.flatten.uniq
    end

    def refresh_plugins(path = '/')
      parts = path.split('/')
      if parts.length == 0
        h = @metadata
      else
        parts.shift if parts[0].length == 0 
        h = @metadata
        parts.each do |part|
          break unless h.has_key?(part)
          h = h[part]
        end
      end

      refreshments = collect_providers(h)
      Ohai::Log.debug("Refreshing plugins: #{refreshments.join(", ")}")
      
      # remove the hints cache
      @hints = Hash.new

      refreshments.each do |r|
        @seen_plugins.delete(r) if @seen_plugins.has_key?(r)
      end
      refreshments.each do |r|
        require_plugin(r) unless @seen_plugins.has_key?(r)
      end
    end

    def require_plugin(plugin_name, force=false)
      unless force
        return true if @seen_plugins[plugin_name]
      end

      if Ohai::Config[:disabled_plugins].include?(plugin_name)
        Ohai::Log.debug("Skipping disabled plugin #{plugin_name}")
        return false
      end

      if plugin = plugin_for(plugin_name)
        @seen_plugins[plugin_name] = true
        begin
          plugin.run
          true
        rescue SystemExit, Interrupt
          raise
        rescue Exception,Errno::ENOENT => e
          Ohai::Log.debug("Plugin #{plugin_name} threw exception #{e.inspect} #{e.backtrace.join("\n")}")
        end
      else
        Ohai::Log.debug("No #{plugin_name} found in #{Ohai::Config[:plugin_path]}")
      end
    end

    def plugin_for(plugin_name)
      filename = "#{plugin_name.gsub("::", File::SEPARATOR)}.rb"

      plugin = nil

      Ohai::Config[:plugin_path].each do |path|
        check_path = File.expand_path(File.join(path, filename))
        if File.exist?(check_path)
          plugin = DSL::Plugin.new(self, filename.split('.')[0], check_path)
          break
        else
          next
        end
      end
      plugin
    end

    # Serialize this object as a hash
    def to_json
      Yajl::Encoder.new.encode(@data)
    end

    # Pretty Print this object as JSON
    def json_pretty_print(item=nil)
      Yajl::Encoder.new(:pretty => true).encode(item || @data)
    end

    def attributes_print(a)
      data = @data
      a.split("/").each do |part|
        data = data[part]
      end
      raise ArgumentError, "I cannot find an attribute named #{a}!" if data.nil?
      case data
      when Hash,Mash,Array,Fixnum
        json_pretty_print(data)
      when String
        if data.respond_to?(:lines)
          json_pretty_print(data.lines.to_a)
        else
          json_pretty_print(data.to_a)
        end
      else
        raise ArgumentError, "I can only generate JSON for Hashes, Mashes, Arrays and Strings. You fed me a #{data.class}!"
      end
    end

    private

    def run_providers(providers, safe)
      begin
        providers.each { |provider| run_plugin(provider, safe) }
      rescue DependencyCycleError, NoAttributeError => e
        Ohai::Log.error("Encountered error when running plugins: #{e.inspect}")
        raise
      end
    end

    def run_plugin(plugin, safe)
      return if plugin.has_run?
      
      visited = [plugin]
      while !visited.empty?
        p = visited.pop

        if visited.include?(p)
          visited.drop_while { |plugin| !plugin.eql?(p) }
          cycle_str = ""
          visited.each { |plugin| cycle_str << "#{plugin.source}, " }
          cycle_str << p.source

          Ohai::Log.debug("Dependency cycle detected: #{cycle_str}")
          raise DependencyCycleError, "Dependency cycle detected. This must be resolved before the run can continue. Check the debug log for more information."
        end

        providers = []
        begin
          p.dependencies.each { |dependency| providers << fetch_providers(dependency) }
        rescue NoAttributeError
          raise
        end
        providers = providers.flatten.uniq
        providers.delete_if { |provider| provider.has_run? || provider.eql?(p) }
        
        if providers.empty?
          safe ? p.safe_run : p.run
        else
          visited << p
          visited << providers
          visited.flatten!
        end
      end
    end

    def fetch_providers(attribute)
      a = @attributes

      parts = attribute.split('/')
      parts.each do |part|
        next if part == Ohai::OS.collect_os

        raise NoAttributeError, "Cannot find plugin providing attribute \'#{attribute}\'" unless a[part]
        a = a[part]
      end

      a[:providers]
    end

    def compute_cycle(cycle)
      filenames = []
      @v6_dependency_solver.each { |file| filenames << file if cycle.include?(file) }

      ordered_files = Array.new(cycle.size + 1)
      filenames.each { |file| ordered_files.insert(cycle.index_of(@v6_dependency_solver[file]), @v6_dependency_solver[file]) }
      

      ordered_files
    end

  end
end
