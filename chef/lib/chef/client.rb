#
# Author:: Adam Jacob (<adam@opscode.com>)
# Author:: Christopher Walters (<cw@opscode.com>)
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

require 'chef/config'
require 'chef/mixin/params_validate'
require 'chef/mixin/generate_url'
require 'chef/mixin/checksum'
require 'chef/log'
require 'chef/rest'
require 'chef/platform'
require 'chef/node'
require 'chef/role'
require 'chef/file_cache'
require 'chef/compile'
require 'chef/runner'
require 'ohai'

class Chef
  class Client
    
    include Chef::Mixin::GenerateURL
    include Chef::Mixin::Checksum
    
    attr_accessor :node, :registration, :safe_name, :json_attribs, :validation_token, :node_name, :ohai
    
    # Creates a new Chef::Client.
    def initialize()
      @node = nil
      @safe_name = nil
      @validation_token = nil
      @registration = nil
      @json_attribs = nil
      @node_name = nil
      @node_exists = true 
      Mixlib::Authentication::Log.logger = Ohai::Log.logger = Chef::Log.logger
      @ohai = Ohai::System.new
      @ohai_has_run = false
      if File.exists?(Chef::Config[:client_key])
        @rest = Chef::REST.new(Chef::Config[:chef_server_url])
      else
        @rest = Chef::REST.new(Chef::Config[:chef_server_url], nil, nil)
      end
    end
    
    # Do a full run for this Chef::Client.  Calls:
    # 
    #  * build_node - Get the last known state, merge with local changes
    #  * register - Make sure we have an openid
    #  * authenticate - Authenticate with our openid
    #  * sync_library_files - Populate the local cache with all the library files
    #  * sync_provider_files - Populate the local cache with all the provider files
    #  * sync_resource_files - Populate the local cache with all the resource files
    #  * sync_attribute_files - Populate the local cache with all the attribute files
    #  * sync_definitions - Populate the local cache with all the definitions
    #  * sync_recipes - Populate the local cache with all the recipes
    #  * do_attribute_files - Populate the local cache with all attributes, and execute them
    #  * save_node - Store the new node configuration
    #  * converge - Bring this system up to date, based on the local cache
    #  * save_node - Store the node again, in case convergence altered future state
    #
    # === Returns
    # true:: Always returns true.
    def run
      start_time = Time.now
      Chef::Log.info("Starting Chef Run")
      
      determine_node_name
      register
      build_node(@node_name)
      save_node
      sync_cookbooks
      save_node
      converge
      save_node
      
      end_time = Time.now
      Chef::Log.info("Chef Run complete in #{end_time - start_time} seconds")
      true
    end
    
    # Similar to Chef::Client#run, but instead of talking to the Chef server,
    # simply runs in a standalone ("solo") mode.
    #
    # Someday, we'll have chef_chewbacca.
    #
    # === Returns
    # true:: Always returns true.
    def run_solo
      start_time = Time.now
      Chef::Log.info("Starting Chef Solo Run")

      determine_node_name
      build_node(@node_name, true)
      converge(true)
      
      end_time = Time.now
      Chef::Log.info("Chef Run complete in #{end_time - start_time} seconds")
      true
    end

    def run_ohai
      if ohai.keys
        ohai.refresh_plugins
      else
        ohai.all_plugins
      end
    end

    def determine_node_name
      run_ohai      
      unless safe_name && node_name
        if Chef::Config[:node_name]
          @node_name = Chef::Config[:node_name]
        else
          @node_name ||= ohai[:fqdn] ? ohai[:fqdn] : ohai[:hostname]
          Chef::Config[:node_name] = @node_name
        end
        @safe_name = @node_name.gsub(/\./, '_')
      end
      @node_name
    end

    # Builds a new node object for this client.  Starts with querying for the FQDN of the current
    # host (unless it is supplied), then merges in the facts from Ohai.
    #
    # === Parameters
    # node_name<String>:: The name of the node to build - defaults to nil
    #
    # === Returns
    # node<Chef::Node>:: Returns the created node object, also stored in @node
    def build_node(node_name=nil, solo=false)
      node_name ||= determine_node_name
      raise RuntimeError, "Unable to determine node name from ohai" unless node_name
      Chef::Log.debug("Building node object for #{@safe_name}")
      unless solo
        begin
          @node = @rest.get_rest("nodes/#{@safe_name}")
        rescue Net::HTTPServerException => e
          unless e.message =~ /^404/
            raise e
          end
        end
      end
      unless @node
        @node_exists = false
        @node ||= Chef::Node.new
        @node.name(node_name)
      end
      if @json_attribs
        Chef::Log.debug("Adding JSON Attributes")
        @json_attribs.each do |key, value|
          if key == "recipes" || key == "run_list"
            value.each do |recipe|
              unless @node.recipes.detect { |r| r == recipe }
                Chef::Log.debug("Adding recipe #{recipe}")
                @node.recipes << recipe
              end
            end
          else
            Chef::Log.debug("JSON Attribute: #{key} - #{value.inspect}")
            @node[key] = value
          end
        end
      end
      ohai.each do |field, value|
        Chef::Log.debug("Ohai Attribute: #{field} - #{value.inspect}")
        @node[field] = value
      end
      platform, version = Chef::Platform.find_platform_and_version(@node)
      Chef::Log.debug("Platform is #{platform} version #{version}")
      @node[:platform] = platform
      @node[:platform_version] = version
      @node[:tags] = Array.new unless @node.attribute?(:tags)
      @node
    end
   
    # 
    # === Returns
    # true:: Always returns true
    def register
      if File.exists?(Chef::Config[:validation_key])
        @vr = Chef::REST.new(Chef::Config[:client_url], Chef::Config[:validation_client_name], Chef::Config[:validation_key])
        @vr.register(@node_name, Chef::Config[:client_key])
      else
        Chef::Log.debug("Validation key #{Chef::Config[:validation_key]} is not present - skipping registration")
      end
      # We now have the client key, and should use it from now on.
      @rest = Chef::REST.new(Chef::Config[:chef_server_url])
      true
    end
    
    # Update the file caches for a given cache segment.  Takes a segment name
    # and a hash that matches one of the cookbooks/_attribute_files style
    # remote file listings.
    #
    # === Parameters
    # segment<String>:: The cache segment to update
    # remote_list<Hash>:: A cookbooks/_attribute_files style remote file listing
    def update_file_cache(cookbook_name, parts)  
      Chef::Log.debug("Synchronizing cookbook #{cookbook_name}")

      file_canonical = Hash.new

      [ "recipes", "attributes", "definitions", "libraries", "resources", "providers" ].each do |segment|
        remote_list = parts.has_key?(segment) ? parts[segment] : []

        # segement = cookbook segment
        # remote_list = list of file hashes
        #
        # We need the list of known good attribute files, so we can delete any that are
        # just laying about.
        
        remote_list.each do |rf|
          cache_file = File.join("cookbooks", cookbook_name, segment, rf['name'])
          file_canonical[cache_file] = true

          # For back-compat between older clients and new chef servers
          rf['checksum'] ||= nil 
        
          current_checksum = nil
          if Chef::FileCache.has_key?(cache_file)
            current_checksum = checksum(Chef::FileCache.load(cache_file, false))
          end

          rf_url = generate_cookbook_url(
            rf['name'], 
            cookbook_name, 
            segment, 
            @node, 
            current_checksum ? { 'checksum' => current_checksum } : nil
          )
          if current_checksum != rf['checksum']
            changed = true
            begin
              raw_file = @rest.get_rest(rf_url, true)
            rescue Net::HTTPRetriableError => e
              if e.response.kind_of?(Net::HTTPNotModified)
                changed = false
                Chef::Log.debug("Cache file #{cache_file} is unchanged")
              else
                raise e
              end
            end

            if changed
              Chef::Log.info("Storing updated #{cache_file} in the cache.")
              Chef::FileCache.move_to(raw_file.path, cache_file)
            end
          end
        end

        Chef::FileCache.list.each do |cache_file|
          if cache_file =~ /^cookbooks\/(recipes|attributes|definitions|libraries)\//
            unless file_canonical[cache_file]
              Chef::Log.info("Removing #{cache_file} from the cache; it is no longer on the server.")
              Chef::FileCache.delete(cache_file)
            end
          end
        end

      end
      
    end

    # Synchronizes all the cookbooks from the chef-server.
    #
    # === Returns
    # true:: Always returns true
    def sync_cookbooks
      Chef::Log.debug("Synchronizing cookbooks")
      cookbook_hash = @rest.get_rest("nodes/#{@safe_name}/cookbooks")
      Chef::Log.debug("Cookbooks to load: #{cookbook_hash.inspect}")
      cookbook_hash.each do |cookbook_name, parts|
        update_file_cache(cookbook_name, parts)
      end
    end
    
    # Updates the current node configuration on the server.
    #
    # === Returns
    # true:: Always returns true
    def save_node
      Chef::Log.debug("Saving the current state of node #{@safe_name}")
      if @node_exists
        @node = @rest.put_rest("nodes/#{@safe_name}", @node)
      else
        result = @rest.post_rest("nodes", @node)
        @node = @rest.get_rest(result['uri'])
        @node_exists = true
      end
      true
    end
    
    # Compiles the full list of recipes for the server, and passes it to an instance of
    # Chef::Runner.converge.
    #
    # === Returns
    # true:: Always returns true
    def converge(solo=false)
      Chef::Log.debug("Compiling recipes for node #{@safe_name}")
      unless solo
        Chef::Config[:cookbook_path] = File.join(Chef::Config[:file_cache_path], "cookbooks")
      end
      compile = Chef::Compile.new(@node)
      
      Chef::Log.debug("Converging node #{@safe_name}")
      cr = Chef::Runner.new(@node, compile.collection, compile.definitions, compile.cookbook_loader)
      cr.converge
      true
    end

  end
end
