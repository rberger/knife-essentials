require 'chef_fs/file_system/rest_list_dir'
require 'chef_fs/file_system/cookbook_subdir'
require 'chef_fs/file_system/cookbook_file'
require 'chef_fs/file_system/not_found_error'
require 'chef/cookbook_version'

module ChefFS
  module FileSystem
    class CookbookDir < BaseFSDir
      def initialize(name, parent, versions = nil)
        super(name, parent)
        @versions = versions
      end

      attr_reader :versions

      COOKBOOK_SEGMENT_INFO = {
        :attributes => { :ruby_only => true },
        :definitions => { :ruby_only => true },
        :recipes => { :ruby_only => true },
        :libraries => { :ruby_only => true },
        :templates => { :recursive => true },
        :files => { :recursive => true },
        :resources => { :ruby_only => true, :recursive => true },
        :providers => { :ruby_only => true, :recursive => true },
        :root_files => { }
      }

      def add_child(child)
        @children << child
      end

      def api_path
        "#{parent.api_path}/#{name}/_latest"
      end

      def child(name)
        # Since we're ignoring the rules and doing a network request here,
        # we need to make sure we don't rethrow the exception.  (child(name)
        # is not supposed to fail.)
        begin
          result = children.select { |child| child.name == name }.first
          return result if result
        rescue ChefFS::FileSystem::NotFoundError
        end
        return NonexistentFSObject.new(name, self)
      end

      def can_have_child?(name, is_dir)
        # A cookbook's root may not have directories unless they are segment directories
        if is_dir
          return name != 'root_files' && COOKBOOK_SEGMENT_INFO.keys.any? { |segment| segment.to_s == name }
        end
        true
      end

      def children
        if @children.nil?
          @children = []
          COOKBOOK_SEGMENT_INFO.each do |segment, segment_info|
            next unless manifest.has_key?(segment)

            # Go through each file in the manifest for the segment, and
            # add cookbook subdirs and files for it.
            manifest[segment].each do |segment_file|
              parts = segment_file[:path].split('/')
              # Get or create the path to the file
              container = self
              parts[0,parts.length-1].each do |part|
                old_container = container
                container = old_container.children.select { |child| part == child.name }.first
                if !container
                  container = CookbookSubdir.new(part, old_container, segment_info[:ruby_only], segment_info[:recursive])
                  old_container.add_child(container)
                end
              end
              # Create the file itself
              container.add_child(CookbookFile.new(parts[parts.length-1], container, segment_file))
            end
          end
        end
        @children
      end

      def dir?
        exists?
      end

      def read
        # This will only be called if dir? is false, which means exists? is false.
        raise ChefFS::FileSystem::NotFoundError, path_for_printing
      end

      def exists?
        if !@versions
          child = parent.children.select { |child| child.name == name }.first
          @versions = child.versions if child
        end
        !!@versions
      end

      def rest
        parent.rest
      end

      private

      def manifest
        # The negative (not found) response is cached
        if @could_not_get_manifest
          raise ChefFS::FileSystem::NotFoundError.new(@could_not_get_manifest), "#{path_for_printing} not found"
        end

        begin
          # We want to fail fast, for now, because of the 500 issue :/
          # This will make things worse for parallelism, a little.
          old_retry_count = Chef::Config[:http_retry_count]
          begin
            Chef::Config[:http_retry_count] = 0
            @manifest ||= rest.get_rest(api_path).manifest
          ensure
            Chef::Config[:http_retry_count] = old_retry_count
          end
        rescue Net::HTTPServerException
          if $!.response.code == "404"
            @could_not_get_manifest = $!
            raise ChefFS::FileSystem::NotFoundError.new(@could_not_get_manifest), "#{path_for_printing} not found"
          else
            raise
          end

        # Chef bug http://tickets.opscode.com/browse/CHEF-3066 ... instead of 404 we get 500 right now.
        # Remove this when that bug is fixed.
        rescue Net::HTTPFatalError
          if $!.response.code == "500"
            @could_not_get_manifest = $!
            raise ChefFS::FileSystem::NotFoundError.new(@could_not_get_manifest), "#{path_for_printing} not found"
          else
            raise
          end
        end
      end
    end
  end
end
