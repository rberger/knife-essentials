require 'chef_fs/diff'

module ChefFS
  module CommandLine
    def self.diff(pattern, a_root, b_root, recurse_depth, output_mode)
      found_result = false
      ChefFS::Diff::diffable_leaves_from_pattern(pattern, a_root, b_root, recurse_depth) do |a_leaf, b_leaf|
        found_result = true
        diff = diff_leaves(a_leaf, b_leaf, output_mode)
        yield diff if diff != ''
      end
      if !found_result && pattern.exact_path
        yield "#{pattern}: No such file or directory on remote or local"
      end
    end

    private

    # Diff two known leaves (could be files or dirs)
    def self.diff_leaves(old_file, new_file, output_mode)
      result = ''
      # If both are directories
      # If old is a directory and new is a file
      # If old is a directory and new does not exist
      if old_file.dir?
        if new_file.dir?
          if output_mode != :name_only && output_mode != :name_status
            result << "Common subdirectories: #{old_file.path}\n"
          end
        elsif new_file.exists?
          if output_mode == :name_only
            result << "#{new_file.path_for_printing}\n"
          elsif output_mode == :name_status
            result << "T\t#{new_file.path_for_printing}\n"
          else
            result << "File #{new_file.path_for_printing} is a directory while file #{new_file.path_for_printing} is a regular file\n"
          end
        elsif new_file.parent.can_have_child?(old_file.name, old_file.dir?)
          if output_mode == :name_only
            result << "#{new_file.path_for_printing}\n"
          elsif output_mode == :name_status
            result << "D\t#{new_file.path_for_printing}\n"
          else
            result << "Only in #{old_file.parent.path_for_printing}: #{old_file.name}\n"
          end
        end

      # If new is a directory and old does not exist
      # If new is a directory and old is a file
      elsif new_file.dir?
        if old_file.exists?
          if output_mode == :name_only
            result << "#{new_file.path_for_printing}\n"
          elsif output_mode == :name_status
            result << "T\t#{new_file.path_for_printing}\n"
          else
            result << "File #{old_file.path_for_printing} is a regular file while file #{old_file.path_for_printing} is a directory\n"
          end
        elsif old_file.parent.can_have_child?(new_file.name, new_file.dir?)
          if output_mode == :name_only
            result << "#{new_file.path_for_printing}\n"
          elsif output_mode == :name_status
            result << "A\t#{new_file.path_for_printing}\n"
          else
            result << "Only in #{new_file.parent.path_for_printing}: #{new_file.name}\n"
          end
        end

      else
        # Neither is a directory, so they are diffable with file diff
        different, old_value, new_value = ChefFS::Diff::diff_files(old_file, new_file)
        if different
          # If one of the files doesn't exist, we only want to print the diff if the
          # other file *could be uploaded/downloaded*.
          if !old_value && !old_file.parent.can_have_child?(new_file.name, new_file.dir?)
            return result
          end
          if !new_value && !new_file.parent.can_have_child?(old_file.name, old_file.dir?)
            return result
          end

          if output_mode == :name_only
            result << "#{new_file.path_for_printing}\n"
          elsif output_mode == :name_status
            if !old_value
              result << "A\t#{new_file.path_for_printing}\n"
            elsif !new_value
              result << "D\t#{new_file.path_for_printing}\n"
            else
              result << "M\t#{new_file.path_for_printing}\n"
            end
          else
            old_path = old_file.path_for_printing
            new_path = new_file.path_for_printing
            result << "diff --knife #{old_path} #{new_path}\n"
            if !old_value
              result << "new file\n"
              old_path = "/dev/null"
              old_value = ''
            end
            if !new_value
              result << "deleted file\n"
              new_path = "/dev/null"
              new_value = ''
            end
            result << diff_text(old_path, new_path, old_value, new_value)
          end
        end
      end
      return result
    end

    def self.diff_text(old_path, new_path, old_value, new_value)
      # Copy to tempfiles before diffing
      # TODO don't copy things that are already in files!  Or find an in-memory diff algorithm
      begin
        new_tempfile = Tempfile.new("new")
        new_tempfile.write(new_value)
        new_tempfile.close

        begin
          old_tempfile = Tempfile.new("old")
          old_tempfile.write(old_value)
          old_tempfile.close

          result = `diff -u #{old_tempfile.path} #{new_tempfile.path}`
          result = result.gsub(/^--- #{old_tempfile.path}/, "--- #{old_path}")
          result = result.gsub(/^\+\+\+ #{new_tempfile.path}/, "+++ #{new_path}")
          result
        ensure
          old_tempfile.close!
        end
      ensure
        new_tempfile.close!
      end
    end
  end
end
