#!/usr/bin/env ruby
# Adds new source files to the correct Xcode targets based on simple glob rules.
# Uses Xcodeproj (already shipped with fastlane) so it can run in CI before building.

require "digest"
require "fileutils"
require "json"
require "open3"
require "set"
require "time"
require "tmpdir"
require "pathname"
require "xcodeproj"
require_relative "sync_project_files_config"

PROJECT_ROOT = ENV["GITHUB_WORKSPACE"] ? File.expand_path(ENV["GITHUB_WORKSPACE"]) : File.expand_path("..", __dir__)
PROJECT_PATH = File.join(PROJECT_ROOT, "Trio.xcodeproj")
BASE_REF_ENV = ENV["SYNC_BASE_REF"] || ENV["BASE_REF"] || ENV["BASE_BRANCH"]
BASELINE_PATH = ENV["SYNC_BASELINE_PATH"] || File.join(PROJECT_ROOT, ".sync_baseline.json")
REQUIRE_BASELINE = ENV["SYNC_REQUIRE_BASELINE"] == "1"

def normalize_explicit_path(path)
  stripped = path.to_s.strip
  return nil if stripped.empty?

  stripped = stripped[2..] if stripped.start_with?("./")
  pathname = Pathname.new(stripped)
  if pathname.absolute?
    return pathname.relative_path_from(Pathname.new(PROJECT_ROOT)).to_s
  end
  stripped
end

explicit_files = ARGV.map { |path| normalize_explicit_path(path) }.compact

explicit_list_path = ENV["SYNC_EXPLICIT_FILE_LIST"]
if explicit_list_path && !explicit_list_path.strip.empty? && File.file?(explicit_list_path)
  File.readlines(explicit_list_path, chomp: true).each do |line|
    normalized = normalize_explicit_path(line)
    explicit_files << normalized if normalized
  end
end

# Allow an explicit list of files to be synced (e.g., from patches or build scripts).
EXPLICIT_FILES = explicit_files.uniq

TARGET_GLOBS = SyncProjectFilesConfig::TARGET_GLOBS
TARGET_RESOURCE_GLOBS = SyncProjectFilesConfig::TARGET_RESOURCE_GLOBS
TARGET_PACKAGE_DEPS = SyncProjectFilesConfig::TARGET_PACKAGE_DEPS
TARGET_BUILD_SETTINGS = if SyncProjectFilesConfig.const_defined?(:TARGET_BUILD_SETTINGS)
  SyncProjectFilesConfig::TARGET_BUILD_SETTINGS
else
  {}
end
TARGET_EXCLUDE_GLOBS = if SyncProjectFilesConfig.const_defined?(:TARGET_EXCLUDE_GLOBS)
  SyncProjectFilesConfig::TARGET_EXCLUDE_GLOBS
else
  {}
end
TARGET_BASENAME_PREFERENCES = if SyncProjectFilesConfig.const_defined?(:TARGET_BASENAME_PREFERENCES)
  SyncProjectFilesConfig::TARGET_BASENAME_PREFERENCES
else
  {}
end
TARGET_BUILT_PRODUCT_FRAMEWORKS = if SyncProjectFilesConfig.const_defined?(:TARGET_BUILT_PRODUCT_FRAMEWORKS)
  SyncProjectFilesConfig::TARGET_BUILT_PRODUCT_FRAMEWORKS
else
  {}
end

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
  # Separate explicit file paths (not globs) from glob patterns
  explicit_paths = patterns.select { |p| !p.include?("*") && !p.include?("{") }
  glob_patterns = patterns - explicit_paths
  
  # Always include explicit file paths (like "Trio Watch Shared/TrioComplicationDataStore.swift")
  # even when explicit files are provided, since these are required by the config
  always_include = explicit_paths.select { |path| File.file?(path) }
  
  if EXPLICIT_FILES.any?
    explicit_matches = EXPLICIT_FILES.select { |path| matches_patterns?(path, patterns) }
                                     .select { |path| File.file?(path) }
    # Merge explicit matches with always-include files
    result = (explicit_matches + always_include).uniq.sort
    # When explicit files are provided, we still need to process glob patterns to ensure
    # all required files are in targets (like ExtensionDelegate.swift). The already_in_phase?
    # check will prevent duplicates, so this is safe.
    if ENV["SYNC_EXPLICIT_ONLY"] != "1"
      glob_matches = glob_patterns.flat_map { |pattern| Dir.glob(pattern) }
                                   .select { |path| File.file?(path) }
      result = (result + glob_matches).uniq.sort
    end
    return result
  end

  # When no explicit files, process all patterns
  glob_matches = glob_patterns.flat_map { |pattern| Dir.glob(pattern) }
                               .select { |path| File.file?(path) }
  
  (glob_matches + always_include).uniq.sort
end

def normalize_path_for_comparison(path)
  return nil unless path
  # Normalize the path: remove leading ./ and resolve to absolute
  normalized = path.to_s.strip
  normalized = normalized[2..] if normalized.start_with?("./")
  begin
    # Try to get absolute path for comparison
    if Pathname.new(normalized).absolute?
      File.expand_path(normalized)
    else
      File.expand_path(normalized, PROJECT_ROOT)
    end
  rescue
    # Fallback to normalized relative path
    normalized
  end
end

def normalize_project_relative_path(path)
  return nil unless path
  stripped = path.to_s.strip
  return nil if stripped.empty?
  stripped = stripped[2..] if stripped.start_with?("./")

  absolute = Pathname.new(stripped).absolute? ? File.expand_path(stripped) : File.expand_path(stripped, PROJECT_ROOT)
  relative = Pathname.new(absolute).relative_path_from(Pathname.new(PROJECT_ROOT)).to_s
  return nil if relative.start_with?("..")

  relative
rescue
  nil
end

def explicit_files_normalized
  @explicit_files_normalized ||= EXPLICIT_FILES.map { |path| normalize_project_relative_path(path) }.compact.to_set
end

def explicit_baseline_conflicts
  @explicit_baseline_conflicts ||= Set.new
end

def normalized_filesystem_path(path)
  normalized_path = path.start_with?("./") ? path[2..] : path
  full_path = File.expand_path(normalized_path, PROJECT_ROOT)
  begin
    resolved_path = File.exist?(full_path) ? File.realpath(full_path) : full_path
  rescue
    resolved_path = full_path
  end
  normalize_path_for_comparison(resolved_path)
end

def git_available?
  system("git rev-parse --git-dir >/dev/null 2>&1")
end

def git_show(ref, path)
  return nil unless ref && git_available?
  stdout, _, status = Open3.capture3("git", "show", "#{ref}:#{path}")
  return nil unless status.success?
  stdout
end

def git_rev_parse(ref)
  return nil unless ref && git_available?
  commit = `git rev-parse #{ref} 2>/dev/null`.strip
  return nil unless $?.success?
  commit
end

def default_base_ref
  return nil unless git_available?
  return "upstream/dev" if system("git rev-parse --verify upstream/dev >/dev/null 2>&1")
  return "dev" if system("git rev-parse --verify dev >/dev/null 2>&1")

  nil
end

def effective_base_ref
  BASE_REF_ENV || default_base_ref
end

def read_baseline_cache(path)
  return nil unless File.file?(path)
  JSON.parse(File.read(path))
rescue
  nil
end

def baseline_cache_valid?(cache, base_ref, pbxproj_hash)
  return false unless cache.is_a?(Hash)
  metadata = cache["_metadata"] || {}
  return false if metadata["pbxproj_sha256"].to_s.empty?
  return false if metadata["pbxproj_sha256"] != pbxproj_hash
  return false if base_ref && metadata["base_ref"] != base_ref

  true
end

def baseline_paths_for_phase(phase)
  return [] unless phase

  phase.files.map do |bf|
    next unless bf.file_ref

    path = if bf.file_ref.respond_to?(:full_path) && bf.file_ref.full_path
      bf.file_ref.full_path.to_s
    else
      bf.file_ref.path
    end

    next if path.nil? || path.empty? || path.include?("${")

    normalize_project_relative_path(path)
  end.compact.uniq.sort
end

def generate_baseline_from_content(content, base_ref, pbxproj_hash)
  Dir.mktmpdir("sync_baseline") do |dir|
    project_dir = File.join(dir, "Trio.xcodeproj")
    FileUtils.mkdir_p(project_dir)
    File.write(File.join(project_dir, "project.pbxproj"), content)

    project = Xcodeproj::Project.open(project_dir)
    target_names = (TARGET_GLOBS.keys + TARGET_RESOURCE_GLOBS.keys).uniq

    baseline = {
      "_metadata" => {
        "generated_at" => Time.now.utc.iso8601,
        "base_ref" => base_ref,
        "base_commit" => git_rev_parse(base_ref),
        "pbxproj_sha256" => pbxproj_hash,
        "version" => 1,
      },
      "targets" => {},
    }

    target_names.each do |target_name|
      target = project.targets.find { |t| t.name == target_name }
      next unless target

      baseline["targets"][target_name] = {
        "sources" => baseline_paths_for_phase(target.source_build_phase),
        "resources" => baseline_paths_for_phase(target.resources_build_phase),
      }
    end

    baseline
  end
end

def build_baseline_sets(cache)
  targets = cache["targets"] || {}
  baseline = {}

  targets.each do |target_name, phases|
    baseline[target_name] = {}
    phases ||= {}

    %w[sources resources].each do |kind|
      files = Array(phases[kind])
      normalized = files.map { |path| normalize_project_relative_path(path) }.compact
      baseline[target_name][kind] = Set.new(normalized)
    end
  end

  baseline
end

def load_or_generate_baseline(base_ref)
  if base_ref.nil? || base_ref.strip.empty?
    if REQUIRE_BASELINE
      warn "ERROR: SYNC_REQUIRE_BASELINE=1 but no BASE_REF provided."
      exit 1
    end
    return nil
  end

  content = git_show(base_ref, "Trio.xcodeproj/project.pbxproj")
  if content.nil? || content.empty?
    if REQUIRE_BASELINE
      warn "ERROR: Could not read project.pbxproj from #{base_ref}."
      exit 1
    end
    warn "⚠️  Could not read upstream project.pbxproj; continuing without baseline."
    return nil
  end

  pbxproj_hash = Digest::SHA256.hexdigest(content)
  cache = read_baseline_cache(BASELINE_PATH)
  if baseline_cache_valid?(cache, base_ref, pbxproj_hash)
    return build_baseline_sets(cache)
  end

  begin
    baseline = generate_baseline_from_content(content, base_ref, pbxproj_hash)
  rescue StandardError => e
    if REQUIRE_BASELINE
      warn "ERROR: Failed to generate baseline: #{e.class}: #{e.message}"
      exit 1
    end
    warn "⚠️  Failed to generate baseline: #{e.class}: #{e.message}"
    return nil
  end

  File.write(BASELINE_PATH, JSON.pretty_generate(baseline))
  build_baseline_sets(baseline)
end

def apply_target_excludes(target_name, files)
  patterns = TARGET_EXCLUDE_GLOBS[target_name] || []
  return files if patterns.empty?

  files.reject { |path| matches_patterns?(path, patterns) }
end

def filter_files_by_baseline(files, target_name, kind, baseline)
  return files unless baseline

  baseline_set = baseline.dig(target_name, kind)
  return files unless baseline_set

  files.select do |path|
    normalized = normalize_project_relative_path(path)
    if normalized && explicit_files_normalized.include?(normalized)
      if baseline_set.include?(normalized) && !explicit_baseline_conflicts.include?(normalized)
        warn "⚠️  Explicit file #{normalized} is already in baseline for #{target_name} (#{kind}); explicit override will be used."
        explicit_baseline_conflicts.add(normalized)
      end
      next true
    end
    normalized.nil? || !baseline_set.include?(normalized)
  end
end

def file_changed_from_base?(path, base_ref)
  return true unless base_ref && git_available?
  return true unless File.file?(path)

  base_content = git_show(base_ref, path)
  return true if base_content.nil?

  current_hash = Digest::SHA256.file(path).hexdigest
  base_hash = Digest::SHA256.hexdigest(base_content)
  current_hash != base_hash
end

def filter_files_by_changes(files, base_ref)
  return files unless base_ref && git_available?

  files.select do |path|
    normalized = normalize_project_relative_path(path)
    next true if normalized && explicit_files_normalized.include?(normalized)
    file_changed_from_base?(path, base_ref)
  end
end

def preferred_path_from_explicit(paths)
  explicit_matches = paths.select do |path|
    normalized = normalize_explicit_path(path)
    normalized && EXPLICIT_FILES.include?(normalized)
  end

  explicit_matches.size == 1 ? explicit_matches.first : nil
end

def preferred_path_from_config(target_name, basename, paths)
  prefs = TARGET_BASENAME_PREFERENCES[target_name] || {}
  patterns = prefs[basename]
  return nil unless patterns

  Array(patterns).each do |pattern|
    matched = paths.find { |path| File.fnmatch?(pattern, path, File::FNM_PATHNAME) }
    return matched if matched
  end

  nil
end

def preferred_path_from_phase(paths, phase)
  return nil unless phase

  candidates = {}
  paths.each do |path|
    normalized = normalized_filesystem_path(path)
    candidates[normalized] = path if normalized
  end

  phase.files.each do |bf|
    next unless bf.file_ref

    bf_real_path = compute_file_ref_real_path(bf.file_ref)
    next unless bf_real_path

    bf_normalized = normalize_path_for_comparison(bf_real_path)
    preferred = candidates[bf_normalized]
    return preferred if preferred
  end

  nil
end

def existing_phase_paths_by_basename(phase)
  result = Hash.new { |hash, key| hash[key] = [] }
  return result unless phase

  phase.files.each do |bf|
    next unless bf.file_ref

    real_path = compute_file_ref_real_path(bf.file_ref)
    next unless real_path

    basename = File.basename(real_path)
    relative = normalize_project_relative_path(real_path) || real_path
    result[basename] << relative
  end

  result.each_value(&:uniq!)
  result
end

def remove_basename_duplicates(phase, basename, preferred_path)
  return [] unless phase

  preferred_normalized = normalized_filesystem_path(preferred_path)
  return [] unless preferred_normalized

  removed = []

  phase.files.to_a.each do |bf|
    next unless bf.file_ref

    bf_real_path = compute_file_ref_real_path(bf.file_ref)
    next unless bf_real_path
    next unless File.basename(bf_real_path) == basename

    bf_normalized = normalize_path_for_comparison(bf_real_path)
    next if bf_normalized == preferred_normalized

    removed << bf_normalized if bf_normalized
    phase.remove_build_file(bf)
  end

  removed
end

def resolve_basename_collisions(target_name, files, phase)
  removals = []
  existing_by_basename = existing_phase_paths_by_basename(phase)
  grouped = files.group_by { |path| File.basename(path) }
  resolved = []

  grouped.each do |basename, paths|
    existing_paths = existing_by_basename[basename] || []
    all_paths = (paths + existing_paths).uniq
    if all_paths.size == 1
      resolved << paths.first
      next
    end

    preferred = preferred_path_from_explicit(paths) ||
                preferred_path_from_config(target_name, basename, all_paths) ||
                preferred_path_from_phase(all_paths, phase) ||
                all_paths.sort.first

    skipped = (paths - [preferred]).sort
    warn "⚠️  Basename collision for #{basename} in #{target_name}; keeping #{preferred} and skipping #{skipped.join(', ')}"

    resolved << preferred if paths.include?(preferred)
    removed = remove_basename_duplicates(phase, basename, preferred)
    removed.each do |path|
      removals << [target_name, phase.display_name, path]
    end
  end

  [resolved, removals]
end

def file_ref_for(project, path)
  normalized_path = path.start_with?("./") ? path[2..] : path
  full_path = File.expand_path(normalized_path, PROJECT_ROOT)
  
  # Resolve to real path to handle symlinks consistently
  begin
    resolved_path = File.exist?(full_path) ? File.realpath(full_path) : full_path
  rescue
    resolved_path = full_path
  end
  
  target_normalized = normalize_path_for_comparison(resolved_path)

  # Only match by real_path to avoid false matches with same-basename files in different directories
  # real_path is the absolute path to the actual file, which is the only reliable way to match
  existing = project.files.find do |f|
    next false unless f
    
    # Compute real_path for this file_ref (handles cases where real_path isn't set)
    f_real_path = compute_file_ref_real_path(f)
    next false unless f_real_path
    
    begin
      f_normalized = normalize_path_for_comparison(f_real_path)
      next true if f_normalized && target_normalized && f_normalized == target_normalized
    rescue
      # Skip if can't normalize
    end
    
    false
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

def compute_file_ref_real_path(file_ref)
  return nil unless file_ref

  # Prefer Xcodeproj's built-in path resolution.
  if file_ref.respond_to?(:real_path)
    begin
      resolved = file_ref.real_path
      if resolved
        resolved_str = resolved.to_s
        unless resolved_str.empty? || resolved_str.include?("${")
          return File.realpath(resolved_str) rescue resolved_str
        end
      end
    rescue
      # Fall through to other strategies.
    end
  end

  if file_ref.respond_to?(:full_path)
    begin
      full_path = file_ref.full_path
      if full_path
        full_str = full_path.to_s
        unless full_str.empty? || full_str.include?("${")
          expanded = Pathname.new(full_str).absolute? ? full_str : File.expand_path(full_str, PROJECT_ROOT)
          return File.realpath(expanded) rescue expanded
        end
      end
    rescue
      # Fall through to manual computation.
    end
  end

  return nil unless file_ref.path

  if Pathname.new(file_ref.path).absolute?
    candidate_paths = [file_ref.path]
  else
    # Compute from the group hierarchy. Try group.path-only first, then allow display_name.
    path_parts_strict = []
    path_parts_fallback = []
    group = file_ref.parent

    while group && group != file_ref.project.main_group
      if group.respond_to?(:path) && group.path && !group.path.empty?
        path_parts_strict.unshift(group.path)
        path_parts_fallback.unshift(group.path)
      elsif group.respond_to?(:display_name) && group.display_name
        # Use display_name only in the fallback path if the strict path doesn't exist.
        path_parts_fallback.unshift(group.display_name)
      end
      group = group.parent
    end

    if file_ref.project&.main_group&.path && !file_ref.project.main_group.path.empty?
      path_parts_strict.unshift(file_ref.project.main_group.path)
      path_parts_fallback.unshift(file_ref.project.main_group.path)
    end

    path_parts_strict << file_ref.path
    path_parts_fallback << file_ref.path
    candidate_paths = [
      File.join(PROJECT_ROOT, *path_parts_strict),
      File.join(PROJECT_ROOT, *path_parts_fallback),
    ]
  end

  candidate_paths.each do |candidate|
    next unless File.exist?(candidate)
    begin
      return File.realpath(candidate)
    rescue
      return candidate
    end
  end

  nil
end

def already_in_phase?(phase, file_ref)
  return false unless file_ref
  
  # Check if there's a build file for this exact file_ref in this phase
  return true if phase.files.any? { |bf| bf.file_ref == file_ref }

  # Compute real_path for the file_ref (handles cases where real_path isn't set)
  file_real_path = compute_file_ref_real_path(file_ref)
  return false unless file_real_path
  
  file_normalized = normalize_path_for_comparison(file_real_path)
  return false unless file_normalized

  # Check by real_path only (most reliable)
  phase.files.any? do |bf|
    next false unless bf.file_ref
    
    bf_real_path = compute_file_ref_real_path(bf.file_ref)
    next false unless bf_real_path
    
    begin
      bf_normalized = normalize_path_for_comparison(bf_real_path)
      next true if bf_normalized && file_normalized && bf_normalized == file_normalized
    rescue
      # Skip if can't normalize
    end
    
    false
  end
end

def dedupe_build_phase(phase)
  # Group build files by normalized real path. Ruby preserves first-seen
  # insertion order, so the kept entry is deterministic.
  groups = {}

  phase.files.to_a.each do |bf|
    next unless bf.file_ref

    real_path = compute_file_ref_real_path(bf.file_ref)
    next unless real_path

    normalized = normalize_path_for_comparison(real_path)
    next unless normalized

    (groups[normalized] ||= []) << bf
  end

  removed_paths = []

  groups.each do |normalized, bfs|
    next if bfs.size <= 1

    # A path can be referenced more than once in a phase either as distinct
    # PBXBuildFile objects (same file) or as the SAME object listed twice —
    # the latter is cruft an upstream pbxproj can carry (e.g. the 0.8.2 bump
    # listed WatchConfigRootView.swift twice in Trio's Sources phase).
    #
    # We can't just remove the "extra" build files: remove_build_file deletes
    # the shared PBXBuildFile object, so removing the second reference to a
    # doubly-listed single object deletes the only entry and the file silently
    # drops out of compilation. Instead remove ALL references for this path and
    # re-add exactly one — the PBXFileReference survives remove_build_file, so
    # the file stays in the target with a single Sources entry.
    file_ref = bfs.first.file_ref
    bfs.uniq(&:uuid).each { |bf| phase.remove_build_file(bf) }
    phase.add_file_reference(file_ref, true)

    removed_paths.concat([normalized] * (bfs.size - 1))
  end

  removed_paths
end

def dedupe_project_build_phases(project)
  removals = []

  project.targets.each do |target|
    target.build_phases.each do |phase|
      next unless phase.respond_to?(:files)

      removed_paths = dedupe_build_phase(phase)
      removed_paths.each do |path|
        removals << [target.name, phase.display_name, path]
      end
    end
  end

  removals
end

def sync_resources(project, baseline, base_ref)
  additions = []
  removals = []
  
  TARGET_RESOURCE_GLOBS.each do |target_name, patterns|
    target = project.targets.find { |t| t.name == target_name }
    unless target
      warn "⚠️  Skipping missing target #{target_name}"
      next
    end

    resources_phase = target.resources_build_phase
    files = resolved_files(patterns)
    files = apply_target_excludes(target_name, files)
    files = filter_files_by_baseline(files, target_name, "resources", baseline)
    files = filter_files_by_changes(files, base_ref)
    files, basename_removals = resolve_basename_collisions(target_name, files, resources_phase)
    removals.concat(basename_removals)

    files.each do |path|
      file_ref = file_ref_for(project, path)
      unless file_ref
        warn "⚠️  Could not find or create file reference for: #{path}"
        next
      end
      
      # Check if already in phase
      if already_in_phase?(resources_phase, file_ref)
        next
      end
      
      # Additional safety check for resources (by real_path only)
      file_real_path = compute_file_ref_real_path(file_ref)
      file_normalized = file_real_path ? normalize_path_for_comparison(file_real_path) : nil
      
      if file_normalized
        is_duplicate = resources_phase.files.any? do |bf|
          next false unless bf.file_ref
          
          next true if bf.file_ref == file_ref
          
          bf_real_path = compute_file_ref_real_path(bf.file_ref)
          if bf_real_path
            begin
              bf_normalized = normalize_path_for_comparison(bf_real_path)
              next true if bf_normalized && file_normalized && bf_normalized == file_normalized
            rescue
              # Skip if can't compare
            end
          end
          
          false
        end
        
        if is_duplicate
          next
        end
      end

      resources_phase.add_file_reference(file_ref, true)
      additions << [target_name, path, "resource"]
    end
  end

  [additions, removals]
end

def sync_package_dependencies(project)
  additions = []
  
  TARGET_PACKAGE_DEPS.each do |target_name, deps|
    target = project.targets.find { |t| t.name == target_name }
    unless target
      warn "⚠️  Skipping missing target #{target_name}"
      next
    end

    deps.each do |dep|
      package_name = dep[:package_name]
      product_name = dep[:product_name]
      
      # Find the package reference by repository URL
      package_ref = project.root_object.package_references.find do |ref|
        ref.repositoryURL&.include?(package_name)
      end
      
      unless package_ref
        warn "⚠️  Package #{package_name} not found in project"
        next
      end

      # Check if dependency already exists
      existing_dep = target.package_product_dependencies.find do |pd|
        pd.package == package_ref && pd.product_name == product_name
      end
      
      if existing_dep
        next
      end

      # Create new package product dependency
      dep_obj = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
      dep_obj.package = package_ref
      dep_obj.product_name = product_name
      
      # Add to target's package dependencies
      target.package_product_dependencies << dep_obj
      
      # Add to frameworks build phase
      frameworks_phase = target.frameworks_build_phase
      build_file = frameworks_phase.add_file_reference(dep_obj, true)
      
      additions << [target_name, "#{package_name}/#{product_name}", "package"]
    end
  end

  additions
end

def built_products_dir_ref?(ref)
  return false unless ref

  st = ref.source_tree
  st == :built_products_dir || st.to_s == "BUILT_PRODUCTS_DIR"
end

def find_built_product_framework_ref(project, framework_path, donor_target_names)
  Array(donor_target_names).compact.each do |name|
    donor = project.targets.find { |t| t.name == name }
    next unless donor

    phase = donor.frameworks_build_phase
    next unless phase

    phase.files.each do |bf|
      ref = bf.file_ref
      next unless ref && ref.path == framework_path && built_products_dir_ref?(ref)

      return ref
    end
  end

  project.files.each do |ref|
    next unless ref.isa == "PBXFileReference"
    next unless ref.path == framework_path && built_products_dir_ref?(ref)

    return ref
  end

  nil
end

def ensure_embed_frameworks_phase(project, target)
  existing = target.build_phases.grep(Xcodeproj::Project::Object::PBXCopyFilesBuildPhase).find do |p|
    p.name == "Embed Frameworks"
  end
  return existing if existing

  phase = project.new(Xcodeproj::Project::Object::PBXCopyFilesBuildPhase)
  phase.name = "Embed Frameworks"
  phase.symbol_dst_subfolder_spec = :frameworks
  # xcodeproj typechecks buildActionMask as String (see AbstractBuildPhase)
  phase.build_action_mask = "2147483647"
  phase.run_only_for_deployment_postprocessing = "0"

  insert_pair = target.build_phases.each_with_index.find do |p, _i|
    p.respond_to?(:name) && p.name == "Embed Foundation Extensions"
  end
  if insert_pair
    target.build_phases.insert(insert_pair[1] + 1, phase)
  else
    target.build_phases << phase
  end

  phase
end

def sync_built_product_frameworks(project)
  additions = []

  TARGET_BUILT_PRODUCT_FRAMEWORKS.each do |target_name, entries|
    target = project.targets.find { |t| t.name == target_name }
    unless target
      warn "⚠️  Skipping built-product frameworks: missing target #{target_name}"
      next
    end

    entries.each do |entry|
      path = entry[:path] || entry["path"]
      donor_names = entry[:donor_target_names] || entry["donor_target_names"] || []
      embed = entry[:embed] != false && entry["embed"] != false

      unless path
        warn "⚠️  Skipping built-product framework entry without :path for #{target_name}"
        next
      end

      file_ref = find_built_product_framework_ref(project, path, donor_names)
      unless file_ref
        warn "⚠️  Could not find PBXFileReference for #{path} (BUILT_PRODUCTS_DIR); skipping #{target_name}"
        next
      end

      fw_phase = target.frameworks_build_phase
      unless already_in_phase?(fw_phase, file_ref)
        fw_phase.add_file_reference(file_ref)
        additions << [target_name, path, "framework_link"]
      end

      next unless embed

      embed_phase = ensure_embed_frameworks_phase(project, target)
      next if already_in_phase?(embed_phase, file_ref)

      bf = embed_phase.add_file_reference(file_ref)
      bf.settings = { "ATTRIBUTES" => %w[CodeSignOnCopy RemoveHeadersOnCopy] }
      additions << [target_name, path, "framework_embed"]
    end
  end

  additions
end

def resolve_build_setting_value(value, config)
  return value unless value.is_a?(Hash)
  name_str = config.name.to_s
  value[config.name] || value[name_str] || value[name_str.to_sym]
end

def sync_build_settings(project)
  changes = []

  TARGET_BUILD_SETTINGS.each do |target_name, settings|
    target = project.targets.find { |t| t.name == target_name }
    unless target
      warn "⚠️  Skipping missing target #{target_name}"
      next
    end

    target.build_configurations.each do |config|
      settings.each do |key, value|
        effective_value = resolve_build_setting_value(value, config)

        if value.is_a?(Hash) && effective_value.nil?
          warn "Skipping #{key} for #{target_name} / #{config.name} (no mapping)"
          next
        end

        current_value = config.build_settings[key]
        next if current_value == effective_value

        config.build_settings[key] = effective_value
        changes << [target_name, config.name, key, effective_value]
      end
    end
  end

  changes
end

def sync_project
  Dir.chdir(PROJECT_ROOT) do
    base_ref = effective_base_ref
    baseline = load_or_generate_baseline(base_ref)
    project = Xcodeproj::Project.open(PROJECT_PATH)
    additions = []
    removals = dedupe_project_build_phases(project)

    # Sync source files
    TARGET_GLOBS.each do |target_name, patterns|
      target = project.targets.find { |t| t.name == target_name }
      unless target
        warn "⚠️  Skipping missing target #{target_name}"
        next
      end

      phase = target.source_build_phase
      files = resolved_files(patterns)
      files = apply_target_excludes(target_name, files)
      files = filter_files_by_baseline(files, target_name, "sources", baseline)
      files = filter_files_by_changes(files, base_ref)
      files, basename_removals = resolve_basename_collisions(target_name, files, phase)
      removals.concat(basename_removals)

      files.each do |path|
        file_ref = file_ref_for(project, path)
        unless file_ref
          warn "⚠️  Could not find or create file reference for: #{path}"
          next
        end
        
        # Double-check: ensure file_ref isn't already in this phase
        if already_in_phase?(phase, file_ref)
          next
        end
        
        # Additional safety check: verify the file_ref isn't a duplicate by checking
        # if any build file in this phase references the same file by real_path
        # (already_in_phase? should catch this, but this is a double-check)
        file_real_path = compute_file_ref_real_path(file_ref)
        file_normalized = file_real_path ? normalize_path_for_comparison(file_real_path) : nil
        
        if file_normalized
          is_duplicate = phase.files.any? do |bf|
            next false unless bf.file_ref
            
            # Check by file_ref identity (already checked above, but safe to check again)
            next true if bf.file_ref == file_ref
            
            # Check by real_path (computed if not available)
            bf_real_path = compute_file_ref_real_path(bf.file_ref)
            if bf_real_path
              begin
                bf_normalized = normalize_path_for_comparison(bf_real_path)
                next true if bf_normalized && file_normalized && bf_normalized == file_normalized
              rescue
                # Skip if can't compare
              end
            end
            
            false
          end
          
          if is_duplicate
            next
          end
        end
        
        # Not in phase, add it
        phase.add_file_reference(file_ref, true)
        additions << [target_name, path, "source"]
      end
    end

    # Sync resource files
    resource_additions, resource_removals = sync_resources(project, baseline, base_ref)
    additions.concat(resource_additions)
    removals.concat(resource_removals)

    # Sync package dependencies
    additions.concat(sync_package_dependencies(project))

    additions.concat(sync_built_product_frameworks(project))

    # Sync build settings
    build_setting_changes = sync_build_settings(project)

    project.save

    if additions.empty? && removals.empty? && build_setting_changes.empty?
      puts "No new files, dependencies, or build settings to update."
    else
      removals.each do |target, phase, path|
        puts "Removed duplicate #{path} -> #{target} (#{phase})"
      end

      additions.each do |target, path, type|
        puts "Added #{path} -> #{target} (#{type})"
      end

      build_setting_changes.each do |target, config, key, value|
        puts "Updated #{target} (#{config}): #{key} = #{value}"
      end
    end
  end
end

if ENV["SYNC_ONLY_BUILT_PRODUCT_FRAMEWORKS"] == "1"
  Dir.chdir(PROJECT_ROOT) do
    project = Xcodeproj::Project.open(PROJECT_PATH)
    removals = []
    removals = dedupe_project_build_phases(project) unless ENV["SYNC_SKIP_DEDUPE"] == "1"
    additions = sync_built_product_frameworks(project)
    project.save

    removals.each do |target, phase, path|
      puts "Removed duplicate #{path} -> #{target} (#{phase})"
    end

    additions.each do |target, path, type|
      puts "Added #{path} -> #{target} (#{type})"
    end

    puts "Done (SYNC_ONLY_BUILT_PRODUCT_FRAMEWORKS=1)." if additions.empty? && removals.empty?
  end
else
  sync_project
end
