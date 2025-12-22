#!/usr/bin/env ruby
# Adds new source files to the correct Xcode targets based on simple glob rules.
# Uses Xcodeproj (already shipped with fastlane) so it can run in CI before building.

require "set"
require "pathname"
require "xcodeproj"

PROJECT_ROOT = ENV["GITHUB_WORKSPACE"] ? File.expand_path(ENV["GITHUB_WORKSPACE"]) : File.expand_path("..", __dir__)
PROJECT_PATH = File.join(PROJECT_ROOT, "Trio.xcodeproj")

# Allow an explicit list of files to be synced (e.g., from patches).
EXPLICIT_FILES = ARGV.map(&:strip)
                      .reject(&:empty?)
                      .map { |path| path.start_with?("./") ? path[2..] : path }
                      .map do |path|
                        Pathname.new(path).absolute? ? Pathname.new(path).relative_path_from(Pathname.new(PROJECT_ROOT)).to_s : path
                      end
                      .uniq

# Map target names to the globs that should feed them.
TARGET_GLOBS = {
  "Trio" => ["Trio/Sources/**/*.{swift,m,mm}"],
  "Trio Watch App" => [
    "Trio Watch App Extension/**/*.{swift,m,mm}",
    "Trio/Sources/Models/NotificationIdentifiers.swift",
    "Trio/Sources/Models/WatchMessageKeys.swift"
  ],
  "Trio Watch Complication Extension" => ["Trio Watch Complication/**/*.{swift,m,mm}"],
  "LiveActivityExtension" => ["LiveActivity/**/*.{swift,m,mm}"]
}.freeze

def expand_brace(pattern)
  return [pattern] unless pattern.include?("{") && pattern.include?("}")

  prefix, rest = pattern.split("{", 2)
  choices, suffix = rest.split("}", 2)
  choices.split(",").map { |choice| "#{prefix}#{choice}#{suffix}" }
end

def matches_patterns?(path, patterns)
  patterns.flat_map { |pattern| expand_brace(pattern) }.any? do |expanded|
    File.fnmatch?(expanded, path, File::FNM_PATHNAME)
  end
end

def resolved_files(patterns)
  if EXPLICIT_FILES.empty?
    patterns.flat_map { |pattern| Dir.glob(pattern) }
            .select { |path| File.file?(path) }
            .uniq
            .sort
  else
    EXPLICIT_FILES.select { |path| matches_patterns?(path, patterns) }
                  .select { |path| File.file?(path) }
                  .uniq
                  .sort
  end
end

def file_ref_for(project, path)
  normalized_path = path.start_with?("./") ? path[2..] : path
  full_path = File.expand_path(normalized_path, PROJECT_ROOT)

  existing = project.files.find do |f|
    f.path == path ||
      f.path == normalized_path ||
      (f.real_path && File.expand_path(f.real_path.to_s) == full_path)
  end
  return existing if existing

  group = find_or_create_group(project.main_group, File.dirname(normalized_path))
  file_ref = group.new_file(File.basename(normalized_path))
  file_ref.set_source_tree("<group>")
  file_ref
end

def find_or_create_group(root_group, group_path)
  return root_group if group_path.nil? || group_path.empty? || group_path == "."

  current = root_group
  group_path.split("/").each do |part|
    next if part.empty?

    child = current.children.find do |candidate|
      candidate.is_a?(Xcodeproj::Project::Object::PBXGroup) &&
        (candidate.display_name == part || candidate.path == part)
    end

    child ||= current.new_group(part, part)
    current = child
  end

  current
end

def already_in_phase?(phase, file_ref)
  return true if phase.files_references.any? { |ref| ref == file_ref }

  file_real_path = file_ref.real_path ? File.expand_path(file_ref.real_path.to_s) : nil
  return false unless file_real_path

  phase.files_references.any? do |ref|
    next false unless ref && ref.respond_to?(:real_path) && ref.real_path

    File.expand_path(ref.real_path.to_s) == file_real_path
  end
end

def sync_project
  Dir.chdir(PROJECT_ROOT) do
    project = Xcodeproj::Project.open(PROJECT_PATH)
    additions = []

    TARGET_GLOBS.each do |target_name, patterns|
      target = project.targets.find { |t| t.name == target_name }
      unless target
        warn "⚠️  Skipping missing target #{target_name}"
        next
      end

      files = resolved_files(patterns)

      files.each do |path|
        file_ref = file_ref_for(project, path)
        phase = target.source_build_phase
        next if already_in_phase?(phase, file_ref)

        phase.add_file_reference(file_ref, true)
        additions << [target_name, path]
      end
    end

    project.save

    if additions.empty?
      puts "No new source files to add."
    else
      additions.each { |target, path| puts "Added #{path} -> #{target}" }
    end
  end
end

sync_project
