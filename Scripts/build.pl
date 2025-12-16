#!/usr/bin/env perl
# Auto-detect and use perlbrew local library if available (must be before all use statements)
BEGIN {
    # Try to use perlbrew lib if available
    if (my $perlbrew_root = $ENV{PERLBREW_ROOT} || "$ENV{HOME}/perl5/perlbrew") {
        # Check if perlbrew root directory exists
        if (-d $perlbrew_root) {
            # Try to detect current perlbrew perl version
            my $perl_version = '';
            
            # First, check PERLBREW_PERL environment variable (set by perlbrew use)
            if ($ENV{PERLBREW_PERL}) {
                $perl_version = $ENV{PERLBREW_PERL};
            }
            # Second, try to infer from $^X (the perl executable path)
            # Match patterns like: /path/to/perlbrew/perls/perl-5.42.0/bin/perl
            elsif ($^X =~ /perlbrew[^\/]*\/perls\/(perl-[\d.]+)/) {
                $perl_version = $1;
            }
            # Third, try to run perlbrew list (only if perlbrew is in PATH)
            elsif (grep { -x "$_/perlbrew" } split /:/, ($ENV{PATH} || '')) {
                # Suppress stderr by redirecting to /dev/null in the shell
                if (open my $fh, '-|', 'perlbrew list 2>/dev/null') {
                    while (my $line = <$fh>) {
                        if ($line =~ /^\*\s+(\S+)/) {
                            $perl_version = $1;
                            last;
                        }
                    }
                    close $fh;
                }
            }
            
            # Try common local lib names (project-specific or default)
            if ($perl_version) {
                for my $lib_name (qw(dbs-project default)) {
                    my $lib_path = "$perlbrew_root/libs/${perl_version}\@${lib_name}/lib/perl5";
                    if (-d $lib_path) {
                        unshift @INC, $lib_path;
                        last;
                    }
                }
                
                # Fallback: if no named lib found, try to find any local lib for this perl version
                if (!grep { $_ =~ /libs\/${perl_version}\@/ } @INC) {
                    my $libs_dir = "$perlbrew_root/libs";
                    if (-d $libs_dir && opendir my $dh, $libs_dir) {
                        while (my $entry = readdir $dh) {
                            next if $entry =~ /^\./;
                            if ($entry =~ /^\Q${perl_version}\E\@(.+)$/) {
                                my $lib_path = "$libs_dir/$entry/lib/perl5";
                                if (-d $lib_path) {
                                    unshift @INC, $lib_path;
                                    last;
                                }
                            }
                        }
                        closedir $dh;
                    }
                }
            }
        }
    }
}

use strict;
use warnings;
use YAML::XS 'LoadFile';
use Getopt::Long qw(GetOptions);
use IPC::Open3;
use Symbol 'gensym';
use File::Basename;
use Time::Piece;
use Term::ANSIColor;
use File::Find;
use File::stat;
use File::Path qw(make_path);
use File::Copy qw(copy);
use File::Glob qw(bsd_glob);
use POSIX qw(strftime);
use JSON;
use File::Temp qw(tempdir tempfile);
use POSIX qw(:signal_h setsid);
use Data::Dumper;
use Parallel::ForkManager;
use Digest::SHA qw(sha1_hex);
use List::Util qw(all min);
use Scalar::Util qw(blessed);
use Cwd qw(getcwd abs_path);
use File::Spec;

# Determine the caller's working directory (where the script is invoked from)
# This ensures build directories are relative to the project using this script
our $CALLER_CWD = getcwd();

# Add the Scripts directory relative to this script's location, not the current working directory
# Resolve symlinks to find the actual Scripts directory (works when script is symlinked)
use FindBin;
BEGIN {
    # Resolve the actual script path (following symlinks) and get its directory
    # $FindBin::RealBin is the directory of the actual script (resolves symlinks)
    # $FindBin::RealScript is the filename of the actual script
    # If RealBin exists, use it; otherwise resolve the script path manually
    my $script_dir;
    if ($FindBin::RealBin) {
        $script_dir = $FindBin::RealBin;
    } else {
        # Fallback: resolve the script path manually
        my $script_file = File::Spec->catfile($FindBin::Bin, $FindBin::Script);
        my $script_path = abs_path($script_file);
        $script_dir = dirname($script_path);
    }
    unshift @INC, $script_dir;
}

# All use statements at the top - proper Perl practice
use BuildUtils qw(merge_args node_key get_key_from_node format_node traverse_nodes expand_command_args get_node_by_key enumerate_notifications log_info log_warn log_error log_success log_debug log_verbose log_time $VERBOSITY_LEVEL handle_result_hash print_enhanced_tree print_node_tree build_graph_with_worklist print_validation_summary print_parallel_build_order inject_sequential_group_dependencies inject_sequential_dependencies_for_dependencies load_config_entry extract_target_info apply_category_defaults extract_category_defaults extract_all_category_defaults print_final_build_order print_build_order_legend print_true_build_order add_to_ready_queue add_to_groups_ready is_node_in_groups_ready get_eligible_pending_parent_nodes has_ready_nodes get_next_ready_node remove_from_ready_queue remove_from_groups_ready remove_from_ready_pending_parent get_ready_pending_parent_size get_groups_ready_size get_ready_queue_size get_total_queue_sizes is_successful_completion_status is_empty_dependency_group);
use BuildStatusManager;
use BuildNode;
use BuildNodeRegistry;

# Declare global variables
our $STATUS_MANAGER; # Global status manager instance

# Initialize global status manager after all modules are loaded
$STATUS_MANAGER = BuildStatusManager->new;

# --- Make path relative to caller's working directory ---
# WHAT: Converts relative paths to be relative to the caller's CWD instead of the script's location
# HOW: Prepends $CALLER_CWD to relative paths, leaves absolute paths unchanged
# WHY: Ensures build directories are created in the project using this script, not in the dbs directory
# PUBLIC: This function is used internally to handle path resolution
sub make_path_relative_to_caller {
    my $path = shift;
    return $path if File::Spec->file_name_is_absolute($path);
    return File::Spec->catfile($CALLER_CWD, $path);
}

# --- Sanitize log file names ---
# WHAT: Converts any string into a safe filename for log files
# HOW: Replaces all non-alphanumeric characters (except dots, dashes, underscores) with underscores
# WHY: Prevents filesystem issues when creating log files with special characters in names
# INTERNAL: This is an internal utility function, not intended for direct use by build scripts
sub sanitize_log_name {
    my $name = shift;
    $name =~ s/[^a-zA-Z0-9_.-]+/_/g;
    return $name;
}

# --- Find target suggestions for case-insensitive matching ---
# WHAT: Searches for targets that match the given name case-insensitively across all target types
# HOW: Compares the target name against build_groups, tasks, and platforms using case-insensitive matching
# WHY: Provides helpful suggestions when users specify targets with incorrect case
# INTERNAL: This is an internal utility function, not intended for direct use by build scripts
sub find_target_suggestions {
    my ($target, $cfg) = @_;
    my @suggestions;
    my $target_lc = lc($target);
    
    # Search in all target sections
    for my $section (qw(build_groups tasks platforms)) {
        if (exists $cfg->{$section}) {
            if (ref($cfg->{$section}) eq 'HASH') {
                # build_groups is a hash
                for my $target_name (keys %{$cfg->{$section}}) {
            if (lc($target_name) eq $target_lc) {
                push @suggestions, $target_name;
                    }
                }
            } elsif (ref($cfg->{$section}) eq 'ARRAY') {
                # tasks and platforms are arrays
                for my $item (@{$cfg->{$section}}) {
                    if (ref($item) eq 'HASH' && exists $item->{name}) {
                        my $target_name = $item->{name};
                        if (lc($target_name) eq $target_lc) {
                            push @suggestions, $target_name;
                        }
                    }
                }
            }
        }
    }
    
    return @suggestions;
}

# --- Validate target and provide suggestions if not found ---
# WHAT: Checks if a target exists across all target types and provides helpful suggestions if it doesn't
# HOW: First checks exact match in build_groups, tasks, and platforms, then searches for case-insensitive alternatives
# WHY: Helps users quickly identify the correct target name without changing system behavior
# INTERNAL: This is an internal utility function, not intended for direct use by build scripts
sub validate_target_with_suggestions {
    my ($target, $cfg) = @_;
    

    
    # Validate that $cfg is a proper hash reference
    unless (defined($cfg) && ref($cfg) eq 'HASH') {
        return (0, "Configuration error: Configuration not loaded or invalid format. Please check buildconfig.yml syntax.");
    }
    
    # First check for exact match in all target sections
    # Validate that required sections exist and are proper references
    if (exists $cfg->{build_groups} && ref($cfg->{build_groups}) eq 'HASH' && exists $cfg->{build_groups}{$target}) {
        return (1, undef); # Target exists in build_groups
    }
    if (exists $cfg->{tasks} && ref($cfg->{tasks}) eq 'ARRAY') {
        for my $task (@{$cfg->{tasks}}) {
            if (ref($task) eq 'HASH' && exists $task->{name} && $task->{name} eq $target) {
                return (1, undef); # Target exists in tasks
            }
        }
    }
    if (exists $cfg->{platforms} && ref($cfg->{platforms}) eq 'ARRAY') {
        for my $platform (@{$cfg->{platforms}}) {
            if (ref($platform) eq 'HASH' && exists $platform->{name} && $platform->{name} eq $target) {
                return (1, undef); # Target exists in platforms
            }
        }
    }
    
    # If no exact match, look for case-insensitive alternatives
    my @suggestions = find_target_suggestions($target, $cfg);
    
    if (@suggestions == 1) {
        return (0, "Did you mean: '$suggestions[0]'?");
    } elsif (@suggestions > 1) {
        my $suggestion_list = join("', '", @suggestions);
        return (0, "Did you mean one of: '$suggestion_list'?");
    } else {
        # No suggestions found, show available targets from all sections
        my @available;
        for my $section (qw(build_groups tasks platforms)) {
            if (exists $cfg->{$section} && ref($cfg->{$section}) eq 'ARRAY') {
                push @available, map { $_->{name} } @{$cfg->{$section}};
            } elsif (exists $cfg->{$section} && ref($cfg->{$section}) eq 'HASH') {
                push @available, keys %{$cfg->{$section}};
            }
        }
        if (@available) {
            my $available_list = join("', '", sort @available);
            return (0, "Available targets: '$available_list'");
        } else {
            return (0, "No build targets defined in configuration");
        }
    }
}

# --- Config ---
my $CONFIG_FILE = 'buildconfig.yml';
my $DEFAULT_VERBOSITY = 1;
my $config_file_override;

# --- Globals ---
my $verbosity = $DEFAULT_VERBOSITY;
my $target;
my $validate;
my $display;
my $quiet;
my $verbose;
my $debug;
my $dry_run;
my $simulate_failure;
my $help;
my $version;
my $generate_sample_config;
my $print_build_order;
my $print_build_order_json;
my $no_summary;
my $summary;
my $list_targets;
my @execution_order; # Track execution order of targets
my $BUILD_SESSION_DIR; # Directory for this build session's logs

my $VERBOSITY_LEVEL; # Will be set by CLI flags or config file
our $IS_DRY_RUN = 0; # Global flag for dry-run mode
our $IS_VALIDATE = 0; # Global flag for validate mode
our $REGISTRY; # Global BuildNodeRegistry instance

# Global queue variables for BuildNode-based three-queue system
our @READY_PENDING_PARENT_NODES; # BuildNodes waiting for parent approval
our @READY_QUEUE_NODES; # BuildNodes ready to execute
our %GROUPS_READY_NODES; # BuildNode => 1 for groups ready to execute children

my $cfg = undef; # Declare $cfg as a global variable
my $VALIDATE_NOTIFICATION_GRAPH = 0;

# --- Initialize build session directory ---
# WHAT: Creates a unique directory for this build session's logs
# HOW: Uses process ID and timestamp to create a unique session directory
# WHY: Groups all logs from a single build run together for easier analysis
# INTERNAL: This is an internal utility function, not intended for direct use by build scripts
sub init_build_session_dir {
    my $pid = $$;
    my $timestamp = strftime("%Y%m%d_%H%M%S", localtime);
    $BUILD_SESSION_DIR = make_path_relative_to_caller("build/logs/build_${timestamp}_${pid}");
    make_path($BUILD_SESSION_DIR) unless -d $BUILD_SESSION_DIR;
    log_debug("Build session directory: $BUILD_SESSION_DIR");
    return $BUILD_SESSION_DIR;
}

# BuildStatusManager is now global singleton

# --- CLI Parsing ---
GetOptions(
    'target=s' => \$target,
    'validate' => \$validate,
    'display=s' => \$display,
    'quiet'     => \$quiet,
    'verbose'   => \$verbose,
    'debug'     => \$debug,
    'dry-run'   => \$dry_run,
    'simulate-failure=s' => \$simulate_failure,
    'help'      => \$help,
    'version'   => \$version,
    'config=s'  => \$config_file_override,
    'generate-sample-config' => \$generate_sample_config,
    'print-build-order' => \$print_build_order,
    'print-build-order-json' => \$print_build_order_json,
    'no-summary' => \$no_summary,
    'summary'    => \$summary,
    'list-targets' => \$list_targets,
    'validate-notification-graph' => \$VALIDATE_NOTIFICATION_GRAPH,

) or die "Error in command line arguments\n";

# Set verbosity level based on CLI flags
if ($quiet) {
    $VERBOSITY_LEVEL = 0;
} elsif ($debug) {
    $VERBOSITY_LEVEL = 3;
} elsif ($verbose) {
    $VERBOSITY_LEVEL = 2;
}
# If no CLI flags specified, verbosity level will be set from config file

# Set execution mode flags based on CLI flags
$IS_DRY_RUN = $dry_run ? 1 : 0;
$IS_VALIDATE = $validate ? 1 : 0;

# Sync BuildUtils verbosity level if CLI flags were specified
if (defined $VERBOSITY_LEVEL) {
    $BuildUtils::VERBOSITY_LEVEL = $VERBOSITY_LEVEL;
}

# Parse simulate-failure flag into a hash for quick lookup
our %simulate_failure_nodes;
if ($simulate_failure) {
    my @failure_nodes = split(/,/, $simulate_failure);
    for my $node (@failure_nodes) {
        $node =~ s/^\s+|\s+$//g; # Trim whitespace
        $simulate_failure_nodes{$node} = 1;
    }
    log_info("Simulating failures for nodes: " . join(", ", keys %simulate_failure_nodes));
}

# Check for unused arguments
if (@ARGV > 0) {
    log_warn("Unused arguments provided: " . join(" ", @ARGV));
    log_warn("Use --help to see available options");
}

# Enforce mutual exclusivity and implied validation
if (defined $target && ($validate || $display)) {
    die "[ERROR] --target cannot be used with --validate or --display.\n";
}
if (defined $display && !$validate) {
    log_info("--validate is implied by the usage of --display. Running a validation of this target.");
    $validate = 1;
}

if ($help) {
    print <<'USAGE';
Usage: build.pl [options]
  --target <target>           Build (and validate) the specified target (mutually exclusive with --validate/--display)
  --validate                  Validate all groups, display all
  --display <group>           Validate and display only the specified group/target (implies --validate)
  --config <file>             Use specified config file instead of buildconfig.yml
  --quiet                     Suppress most output
  --verbose                   Increase output verbosity
  --debug                     Show debug output
  --dry-run                   Show what would be done, but do not execute
  --simulate-failure <nodes>  Comma-separated list of nodes to simulate as failed (dry-run only)
  --help                      Show this help message
  --version                   Show version information
  --generate-sample-config    Print a sample buildconfig.yml and exit
  --print-build-order         Print build order tree
  --print-build-order-json    Print build order JSON
  --no-summary                Do not print the final build summary
  --summary                   Print the final build summary (default behavior)
  --list-targets              List available platforms, tasks, and build groups
  --validate-notification-graph  Validate notification graph
  

Notes:
  --target is mutually exclusive with --validate and --display.
  --display implies --validate if not provided.
USAGE
    exit 0;
}

if ($version) {
    print "Distributed Build System (DBS) v1.0.0\n";
    exit 0;
}

if ($generate_sample_config) {
    my $sample_file = 'buildconfig.sample.yml';
    if (-e $sample_file) {
        open my $fh, '<', $sample_file or die "Cannot open $sample_file: $!\n";
        print do { local $/; <$fh> };
        close $fh;
    } else {
        print <<'SAMPLE';
# Sample buildconfig.yml
# project_name: Required. The name of your Xcode project (without .xcodeproj). Used for all build commands.
project_name: MyProject
# exclude_from_globals: List of top-level keys that should NOT be propagated as global variables.
exclude_from_globals:
  - tasks
  - platforms
  - build_groups
  - logging
  - exclude_from_globals
  - name
  - args
  - command
  - type
  - dependencies
  - children
platforms:
  - name: macOS
    build_command: ./Scripts/build.sh --target mac
    artifact_dir: build/macos
    artifact_patterns:
      - build/macos/*.app
    # scheme: Required. The Xcode scheme to build for this platform.
    scheme: MyProject macOS
  - name: iOS
    build_command: ./Scripts/build.sh --target ios
    artifact_dir: build/ios
    artifact_patterns:
      - build/ios/*.ipa
    # scheme: Required. The Xcode scheme to build for this platform.
    scheme: MyProject iOS
tasks:
  - name: generate-file-list
    # Example: passing a secret as an environment variable (uncomment to use)
    # command: "MY_SECRET=foo ./myscript.sh $arg1"
    # command: "MY_SECRET=$arg1 ./myscript.sh $arg2"
    # command: "MY_SECRET=$(secret_key_program.sh) ./myscript.sh $arg2"
    command: ./Scripts/generate_file_list.sh
    log_file: build/logs/generate-file-list.log
    always_run: false
    requires: []
  - name: commit-changes
    description: "Commit all changes with version message (optional platform argument)"
    command: "./Scripts/commit_and_tag.sh commit $arg1"
    args_optional: true
build_groups:
  all:
    targets:
      - macOS
      - iOS
SAMPLE
    }
    exit 0;
}

# --- Logging ---
# (Removed local definitions; now imported from BuildUtils)

# --- Load and parse build configuration ---
# WHAT: Loads the YAML configuration file and enhances it with notification support
# HOW: Parses YAML file, normalizes notification fields to array format, creates BuildNode objects for tasks/platforms
# WHY: Provides the foundation configuration for the entire build system with consistent node representation
# INTERNAL: This is an internal function used by the main build script, not intended for direct use
sub load_config {
    my $config_file = $config_file_override || $CONFIG_FILE;
    -f $config_file or die "Config file '$config_file' not found\n";
    
    my $cfg;
    eval {
        $cfg = LoadFile($config_file);
    };
    if ($@) {
        die "Failed to parse YAML configuration file '$config_file': $@\n";
    }
    
    # Validate that we got a hash reference
    unless (ref($cfg) eq 'HASH') {
        die "Configuration file '$config_file' did not parse to a valid hash structure\n";
    }

    # Make all artifact directories relative to the caller's CWD
    if (exists $cfg->{platforms}) {
        for my $platform (@{$cfg->{platforms}}) {
            if (exists $platform->{artifact_dir}) {
                $platform->{artifact_dir} = make_path_relative_to_caller($platform->{artifact_dir});
            }
        }
    }

    # --- Enhance tasks and platforms to support 'notifies' ---
    for my $section (qw(tasks platforms)) {
        next unless exists $cfg->{$section};
        for my $i (0 .. $#{ $cfg->{$section} }) {
            my $item = $cfg->{$section}[$i];
            # If 'notifies' is present, ensure it's an array of hashes
            for my $notif_field (qw(notifies notifies_on_success notifies_on_failure)) {
                if (exists $item->{$notif_field}) {
                    if (ref $item->{$notif_field} eq 'HASH') {
                        $item->{$notif_field} = [ $item->{$notif_field} ];
                    } elsif (ref $item->{$notif_field} ne 'ARRAY') {
                        $item->{$notif_field} = [ { name => $item->{$notif_field} } ];
                    }
                    for my $notify (@{ $item->{$notif_field} }) {
                        if (!ref($notify)) {
                            $notify = { name => $notify };
                        }
                        if (exists $notify->{args} && ref($notify->{args}) ne 'HASH') {
                            log_warn("'args' in $notif_field for $item->{name} is not a hash; ignoring args");
                            delete $notify->{args};
                        }
                        if (exists $notify->{args_from} && $notify->{args_from} ne 'self') {
                            log_warn("'args_from' in $notif_field for $item->{name} is not 'self'; ignoring args_from");
                            delete $notify->{args_from};
                        }
                    }
                }
            }
            # Store config entries as hash references, not BuildNode objects
            # Nodes will be created only when referenced during graph processing
            $item->{type} = $section eq 'tasks' ? 'task' : 'platform';
            $cfg->{$section}[$i] = $item;
        }
    }
    return $cfg;
}



# --- Track execution status for requires_execution_of ---
my %actually_executed; # name => 1 if executed, 0 if skipped

# --- Get log directory path for a node ---
# WHAT: Determines the appropriate log directory path for a build node
# HOW: Uses parent group if available, otherwise uses node name, falls back to base log directory
# WHY: Organizes log files hierarchically to match the build structure and prevent filename conflicts
# INTERNAL: This is an internal utility function, not intended for direct use by build scripts
sub get_log_dir {
    my ($node) = @_;
    my $base = $BUILD_SESSION_DIR || make_path_relative_to_caller("build/logs"); # Fallback to old behavior if session dir not initialized
    my $group = $node->parent_group;
    my $group_name = '';
    if (ref($group) && $group->can('name')) {
        $group_name = sanitize_log_name($group->name);
    } elsif (defined $group && $group ne '') {
        $group_name = sanitize_log_name($group);
    }
    my $node_name = $node->name ? sanitize_log_name($node->name) : '';
    if ($group_name) {
        return "$base/$group_name";
    } elsif ($node_name) {
        return "$base/$node_name";
    } else {
        return $base;
    }
}



# --- Execute a task node with change detection ---
# WHAT: Executes a single task node with input/output change detection and logging
# HOW: Checks if inputs are newer than outputs, expands command arguments, runs command with logging
# WHY: Provides efficient task execution that skips unnecessary work and provides detailed execution logs
# INTERNAL: This is an internal function used by execute_tree_node, not intended for direct use
# sub execute_task_node {# 
#     my ($node, $invocation_id) = @_;
#     $invocation_id //= 1;
#     my $task_name = $node->name;
#     my $args = $node->get_args;
#     my $cmd = $node->command;
#             log_debug("Task '$task_name' command: " . (defined($cmd) ? $cmd : 'UNDEFINED'));
#         log_debug("Task '$task_name' node type: " . ref($node));
#         log_debug("Task '$task_name' node keys: " . join(", ", sort keys %$node));
#     # PATCH: If the command contains ${configuration} and no configuration is provided, use the default from config
#     if (defined($cmd) && $cmd =~ /\$\{configuration\}/ && (!defined($args->{configuration}) || $args->{configuration} eq '')) {
#         my $default_config = $cfg->{configurations}{default} // 'Debug';
#         $args->{configuration} = $default_config;
#     }
#     unless ($cmd) {
#         log_error("Task '$task_name' missing command");
#         $STATUS_MANAGER->set_status($node, 'failed', $invocation_id);
#         log_debug("[STATUS] $task_name set to failed (missing command)");
#         return 0;
#     }
#     my $log_dir = get_log_dir($node);
#     make_path($log_dir) unless -d $log_dir;
#     my $log_file = "$log_dir/task_" . sanitize_log_name($task_name);
#     my $args_str = '';
#     if ($args && ref $args eq 'HASH' && %$args) {
#         $args_str = join("_", map { sanitize_log_name($_ . "_" . $args->{$_}) } sort keys %$args);
#         my $tmp_log_file = $log_file . "_" . $args_str;
#         if (length($tmp_log_file) > 200) {
#             my $hash = substr(sha1_hex($args_str), 0, 10);
#             $log_file .= "_args_" . $hash;
#         } else {
#             $log_file = $tmp_log_file;
#         }
#     }
#     $log_file .= ".log";
#     my $always_run = $node->always_run // 0;
#     my $inputs  = $node->inputs  // [];
#     my $outputs = $node->outputs // [];
#     my $needs_run = $always_run || $node->force_run_due_to_requires_execution_of;
#     if (!$needs_run && @$inputs && @$outputs) {
#         my @input_files;
#         for my $inp (@$inputs) {
#             my @matches = bsd_glob($inp, File::Glob::GLOB_TILDE | File::Glob::GLOB_BRACE);
#             push @input_files, @matches;
#         }
#         my @output_files;
#         for my $out (@$outputs) {
#             my @matches = bsd_glob($out, File::Glob::GLOB_TILDE | File::Glob::GLOB_BRACE);
#             push @output_files, @matches;
#         }
#         if (!@output_files) {
#             $needs_run = 1;
#             log_debug("[CHANGE DETECT] Task '$task_name' needs to run: no output files found.");
#         } else {
#             my $oldest_output = (sort { stat($a)->mtime <=> stat($b)->mtime } @output_files)[0];
#             my $oldest_output_time = stat($oldest_output)->mtime;
#             my $newest_input_time = 0;
#             for my $f (@input_files) {
#                 my $mtime = stat($f)->mtime;
#                 $newest_input_time = $mtime if $mtime > $newest_input_time;
#             }
#             if ($newest_input_time > $oldest_output_time) {
#                 $needs_run = 1;
#                 log_debug("[CHANGE DETECT] Task '$task_name' needs to run: input newer than output.");
#             } else {
#                 $needs_run = 0;
#                 log_debug("[CHANGE DETECT] Task '$task_name' is up-to-date: all outputs newer than all inputs.");
#             }
#         }
#     } elsif (!$needs_run && !@$inputs && !@$outputs) {
#             $needs_run = 1;
#     }
#     if (!$needs_run) {
#         log_info("Task '$task_name' is up-to-date. Skipping.");
#         $STATUS_MANAGER->set_status($node, 'skipped', $invocation_id);
#         log_debug("[STATUS] $task_name set to skipped (up-to-date)");
#         return 1;
#     }
#     my $expanded_cmd = expand_command_args($cmd, $args);
#     if ($dry_run) {
#         log_info("[DRY RUN] Would run: $expanded_cmd");
#         $STATUS_MANAGER->set_status($node, 'dry-run', $invocation_id);
#         return 1;
#     }
#     my $start = time();
#     my $err = gensym;
#     my $pid;
#     open my $lfh, '>', $log_file or die "Cannot open $log_file: $!\n";
#     if ($VERBOSITY_LEVEL == 0) {
#         $pid = open3(undef, \*OUT, $err, $expanded_cmd);
#         while (<OUT>) { print $lfh $_; }
#         while (<$err>) { print $lfh $_; print STDERR $_ if /ERROR|FAIL|CRITICAL/i; }
#         } else {
#         $pid = open3(undef, \*OUT, $err, $expanded_cmd);
#         while (<OUT>) { print; print $lfh $_; }
#         while (<$err>) { print STDERR; print $lfh $_; }
#     }
#     close $lfh;
#     waitpid($pid, 0);
#     my $exit = $? >> 8;
#     my $end = time();
#     $STATUS_MANAGER->set_duration($node, $end - $start, $invocation_id);
#     if ($exit == 0) {
#         log_success("Task '$task_name' completed successfully");
#         my $node_key = $node->key;
#         log_debug("[STATUS_SET] Setting status for $node_key (invocation_id=$invocation_id) to 'done'");
#         $STATUS_MANAGER->set_status($node, 'done', $invocation_id);
#         log_debug("[STATUS] $task_name set to done (success)");
#     } else {
#         log_error("Task '$task_name' failed with exit code $exit");
#         $STATUS_MANAGER->set_status($node, 'failed', $invocation_id);
#         log_debug("[STATUS] $task_name set to failed (exit $exit)");
#     }
#     return $exit == 0;
# }

# --- Execute a platform build node ---
# WHAT: Executes a platform build with command expansion and artifact archiving
# HOW: Expands build command arguments, runs the build command with logging, archives artifacts if specified
# WHY: Handles platform-specific builds (iOS/macOS) with proper logging and artifact management
# INTERNAL: This is an internal function used by execute_tree_node, not intended for direct use
# sub execute_platform_node {
#     my ($node, $invocation_id) = @_;
#     $invocation_id //= 1;
#     my $plat_name = $node->name;
#     log_info("[PLATFORM] Building $plat_name");
#     my $start = time();
#     # Only run the build if needed
#     sleep 1 if $ENV{SIMULATE_BUILD};
#     my $build_cmd = $node->build_command;
#     if ($build_cmd) {
#         my $expanded_cmd = expand_command_args($build_cmd, $node->get_args);
#         my $log_dir = get_log_dir($node);
#         make_path($log_dir) unless -d $log_dir;
#         my $log_file = "$log_dir/platform_" . sanitize_log_name($plat_name) . ".log";
#         if ($dry_run) {
#             log_info("[DRY RUN] Would run: $expanded_cmd");
#             $STATUS_MANAGER->set_status($node, 'dry-run', $invocation_id);
#             return 1;
#         }
#         log_info("Running build command: $expanded_cmd");
#         my $exit;
#         if ($VERBOSITY_LEVEL == 0) {
#             $exit = system("$expanded_cmd > '$log_file' 2>&1");
#         } else {
#             $exit = system("$expanded_cmd 2>&1 | tee '$log_file'");
#         }
#         if ($exit != 0) {
#             log_error("Build command failed for platform '$plat_name' with exit code $exit");
#             $STATUS_MANAGER->set_status($node, 'failed', $invocation_id);
#             log_debug("[STATUS] $plat_name set to failed (exit $exit)");
#             return 0;
#         }
#     } else {
#         log_warn("No build command specified for platform '$plat_name'");
#     }
#     my $end = time();
#     $STATUS_MANAGER->set_status($node, 'done', $invocation_id);
#     log_debug("[STATUS] $plat_name set to done (platform build)");
#     if ($node->archive) {
#         archive_artifacts_for_platform($node);
#     }
#     return 1;
# }

# --- OLD EXECUTION PATH REMOVED ---
# All execution now uses the notification-driven engine via execute_tree_node, execute_task_node, and execute_platform_node

# --- Detect circular dependencies in build groups ---
# WHAT: Identifies circular dependencies between build groups that would cause infinite loops
# HOW: Uses depth-first search with visited tracking to detect cycles in the group dependency graph
# WHY: Prevents build system from getting stuck in infinite loops during graph construction
# PUBLIC: This function is part of the public API and can be used by build scripts for validation
sub detect_cycles {
    my ($cfg, $group, $visited, $path) = @_;
    $visited ||= {};
    $path   ||= [];
    my $cycles = 0;
    $visited->{$group}++;
    push @$path, $group;
    my $targets = $cfg->{build_groups}{$group}{targets} // [];
    for my $tgt (@$targets) {
        my ($name, $args);
        if (ref $tgt eq 'HASH') {
            $name = $tgt->{name};
            $args = $tgt->{args};
        } else {
            $name = $tgt;
            $args = undef;
        }
        if ($visited->{$name}) {
            log_error("Detected cycle: " . join(' -> ', @$path) . " -> $name");
            $cycles++;
            next;
        }
        if ($cfg->{build_groups}{$name}) {
            $cycles += detect_cycles($cfg, $name, { %$visited }, [@$path]);
        }
    }
    pop @$path;
    return $cycles;
}

# --- Print hierarchical tree of build groups ---
# WHAT: Displays the hierarchical structure of build groups and their targets
# HOW: Recursively traverses group dependencies with indentation to show parent-child relationships
# WHY: Provides visual representation of build structure for debugging and understanding build organization
# PUBLIC: This function is part of the public API and can be used by build scripts for debugging
sub print_group_tree {
    my ($cfg, $group, $prefix, $seen) = @_;
    $prefix ||= '';
    $seen ||= {};
    return if $seen->{$group}++;
    print "$prefix$group (group)\n";
    my $targets = $cfg->{build_groups}{$group}{targets} // [];
    for my $tgt (@$targets) {
        my ($name, $args);
        if (ref $tgt eq 'HASH') {
            $name = $tgt->{name};
            $args = $tgt->{args};
        } else {
            $name = $tgt;
            $args = undef;
        }
        my $type =
            (grep { $_->{name} eq $name } @{$cfg->{platforms} // []}) ? 'platform' :
            (grep { $_->{name} eq $name } @{$cfg->{tasks} // []}) ? 'task' :
            ($cfg->{build_groups}{$name} ? 'group' : 'unknown');
        my $argstr = '';
        if (defined $args) {
            if (ref $args eq 'ARRAY') {
                $argstr = ' [' . join(', ', @$args) . ']';
            } elsif (ref $args eq 'HASH') {
                $argstr = ' [' . join(', ', map { "$_=$args->{$_}" } sort keys %$args) . ']';
            }
        }
        print "$prefix  ├─ $name ($type)$argstr\n";
        print_group_tree($cfg, $name, "$prefix  │   ", $seen) if $type eq 'group';
    }
}

# --- Print build order tree with argument propagation ---
# WHAT: Displays the build order tree showing how arguments propagate from parent to child nodes
# HOW: Recursively traverses build groups, merging parent arguments with child arguments, showing the hierarchy
# WHY: Helps developers understand how build arguments flow through the build system hierarchy
# PUBLIC: This function is part of the public API and can be used by build scripts for debugging
sub print_build_order_tree {
    my ($cfg, $target, $prefix, $seen, $parent_args) = @_;
    $prefix ||= '';
    $seen ||= {};
    $target ||= $cfg->{default_target} || 'all';
    $parent_args ||= undef;
    return if $seen->{$target}++;
    print "$prefix$target";
    if ($parent_args && ref $parent_args eq 'HASH' && %$parent_args) {
        print " [" . join(", ", map { "$_=$parent_args->{$_}" } sort keys %$parent_args) . "]";
    }
    print "\n";
    return unless exists $cfg->{build_groups}{$target};
    my $group = $cfg->{build_groups}{$target};
        for my $tgt (@{$group->{targets} // []}) {
        my ($name, $args, $notifies, $requires_execution_of, $instance, $notify_on_success, $notify_on_failure) = extract_target_info($tgt);
        # Simple argument merging without using the old merge_args pattern
        my %merged_args = %{ $parent_args // {} };
        if ($args && ref $args eq 'HASH') {
            %merged_args = (%merged_args, %$args);
        }
        if (exists $cfg->{build_groups}{$name}) {
            print_build_order_tree($cfg, $name, "$prefix  ", $seen, \%merged_args);
        } else {
            print "$prefix  $name";
            if (%merged_args) {
                print " [" . join(", ", map { "$_=$merged_args{$_}" } sort keys %merged_args) . "]";
            }
            print "\n";
        }
    }
}

# --- Generate JSON representation of build order tree ---
# WHAT: Creates a JSON structure representing the complete build order hierarchy with arguments
# HOW: Recursively builds a nested JSON object with name, args, and children arrays
# WHY: Provides machine-readable representation of build structure for external tools or APIs
# PUBLIC: This function is part of the public API and can be used by build scripts for external integration
sub build_order_json {
    my ($cfg, $target, $seen, $parent_args) = @_;
    $seen ||= {};
    $target ||= $cfg->{default_target} || 'all';
    $parent_args ||= undef;
    return undef if $seen->{$target}++;
    unless (exists $cfg->{build_groups}{$target}) {
        my $node = { name => $target };
        if ($parent_args && ref $parent_args eq 'HASH' && %$parent_args) {
            $node->{args} = { %$parent_args };
        }
        return $node;
    }
    my $group = $cfg->{build_groups}{$target};
        return {
            name => $target,
        ( ($parent_args && ref $parent_args eq 'HASH' && %$parent_args) ? (args => { %$parent_args }) : () ),
        children => [map {
            my ($name, $args, $notifies, $requires_execution_of, $instance, $notify_on_success, $notify_on_failure) = extract_target_info($_);
            # Simple argument merging without using the old merge_args pattern
            my %merged_args = %{ $parent_args // {} };
            if ($args && ref $args eq 'HASH') {
                %merged_args = (%merged_args, %$args);
            }
            build_order_json($cfg, $name, $seen, \%merged_args)
        } @{$group->{targets} // []}]
    };
}



# --- Collect build artifacts for a platform ---
# WHAT: Finds and copies build artifacts matching specified patterns to the artifact directory
# HOW: Expands artifact patterns with variables, finds matching files using glob, copies to artifact directory
# WHY: Centralizes build outputs for distribution, archiving, or deployment purposes
# INTERNAL: This is an internal function used by execute_platform_node, not intended for direct use
sub collect_artifacts_for_platform {
    my ($platform, $config) = @_;
    my $artifact_dir = make_path_relative_to_caller($platform->{artifact_dir});
    my $patterns = $platform->{artifact_patterns} // [];
    my $copied = 0;
    for my $pattern (@$patterns) {
        # Expand variables using platform and config as globals
        my %vars = (%$config, %$platform);
        my $expanded = $pattern;
        $expanded =~ s/\$\{(\w+)\}/exists $vars{$1} ? $vars{$1} : ""/ge;
        # Find matching files
        my @matches = bsd_glob($expanded, File::Glob::GLOB_TILDE | File::Glob::GLOB_BRACE);
        for my $file (@matches) {
            next unless -e $file;
            my $dest_dir = $artifact_dir;
            make_path($dest_dir) unless -d $dest_dir;
            my $basename = $file;
            $basename =~ s{.*/}{};
            my $dest = "$dest_dir/$basename";
            if ($file ne $dest) {
                log_info("Copying artifact $file to $dest");
                copy($file, $dest) or log_error("Failed to copy $file to $dest: $!");
                $copied++;
            } else {
                log_debug("Artifact $file is already at destination $dest");
            }
        }
    }
    log_info("Collected $copied artifacts for platform $platform->{name}");
}

# --- Archive platform artifacts ---
# WHAT: Creates compressed archives of platform build artifacts for distribution or backup
# HOW: Uses variable expansion for archive naming, supports zip/tar formats, creates archives in build/archives directory
# WHY: Provides organized artifact storage and enables easy distribution of build outputs
# INTERNAL: This is an internal function used by execute_platform_node, not intended for direct use
sub archive_artifacts_for_platform {
    my ($platform, $config) = @_;
    my $archive_enabled = $config->{artifacts}{archive_enabled} // 0;
    return unless $archive_enabled;
    my $archive_format = $config->{artifacts}{archive_format} // 'zip';
    my $archive_name_template = $config->{artifacts}{archive_name_template} // '{project_name}_{platform}_{version}_{build}_{date}';
    # Use generic variable expansion for archive name
    my %vars = (%$config, %$platform);
    my $current_date = scalar localtime();
    $current_date =~ s/\s+/_/g; $current_date =~ s/:/-/g;
    $vars{date} = $current_date;
    $vars{version} //= '1.00.00'; # TODO: get real version
    $vars{build} //= '01';        # TODO: get real build
    my $archive_name = $archive_name_template;
    $archive_name =~ s/\{(\w+)\}/exists $vars{$1} ? $vars{$1} : ""/ge;
    my $archives_dir = make_path_relative_to_caller('build/archives');
    make_path($archives_dir) unless -d $archives_dir;
    my $archive_path = "$archives_dir/$archive_name.$archive_format";
    my $artifact_dir = make_path_relative_to_caller($platform->{artifact_dir});
    log_info("Archiving artifacts for $platform->{name} to $archive_path");
    my $cmd;
    if ($archive_format eq 'zip') {
        $cmd = "cd '$artifact_dir' && zip -r '$archive_path' .";
    } elsif ($archive_format eq 'tar.gz' || $archive_format eq 'tgz') {
        $cmd = "tar -czf '$archive_path' -C '$artifact_dir' .";
    } elsif ($archive_format eq 'tar') {
        $cmd = "tar -cf '$archive_path' -C '$artifact_dir' .";
    } else {
        log_error("Unsupported archive format: $archive_format");
        return;
    }
    my $result = system($cmd);
    if ($result == 0) {
        log_success("Artifacts archived successfully: $archive_path");
    } else {
        log_error("Failed to create archive for $platform->{name}");
    }
}

# --- Clean up old artifacts based on retention policy ---
# WHAT: Removes old build artifacts according to configured retention policies
# HOW: Delegates to specific cleanup functions based on retention type (simple/hierarchical/bucketed)
# WHY: Prevents disk space issues by automatically removing outdated build artifacts
# INTERNAL: This is an internal function used by execute_platform_node, not intended for direct use
sub cleanup_old_artifacts_for_platform {
    my ($platform, $config) = @_;
    my $cleanup_enabled = $config->{artifacts}{cleanup_enabled} // 0;
    return unless $cleanup_enabled;
    my $retention_type = $config->{artifacts}{retention}{type} // 'simple';
    if ($retention_type eq 'simple') {
        cleanup_simple_retention($platform, $config);
    } elsif ($retention_type eq 'hierarchical') {
        cleanup_hierarchical_retention($platform, $config);
    } elsif ($retention_type eq 'bucketed') {
        cleanup_bucketed_retention($platform, $config);
    } else {
        log_error("Unknown retention type: $retention_type");
    }
}

# --- Clean up artifacts using simple time-based retention ---
# WHAT: Removes artifacts older than a specified number of days
# HOW: Calculates cutoff time, scans artifact directories, deletes files older than cutoff
# WHY: Provides basic disk space management by removing artifacts based on age
# INTERNAL: This is an internal function used by cleanup_old_artifacts_for_platform
sub cleanup_simple_retention {
    my ($platform, $config) = @_;
    my $days = $config->{artifacts}{retention}{simple}{days} // 14;
    my $cutoff = time() - ($days * 24 * 60 * 60);
    my @dirs = (make_path_relative_to_caller($platform->{artifact_dir}), make_path_relative_to_caller('build/archives'));
    for my $dir (@dirs) {
        next unless -d $dir;
        find(sub {
            return unless -f $_;
            my $mtime = (stat($_))[9];
            if ($mtime < $cutoff) {
                log_info("Deleting old artifact: $File::Find::name");
                unlink $File::Find::name;
            }
        }, $dir);
    }
}

# --- Clean up artifacts using hierarchical retention policy ---
# WHAT: Removes artifacts based on multiple time intervals with different retention counts
# HOW: Processes each interval separately, keeps specified number of files per interval, deletes older files
# WHY: Provides more sophisticated retention that keeps more recent artifacts and fewer older ones
# INTERNAL: This is an internal function used by cleanup_old_artifacts_for_platform
sub cleanup_hierarchical_retention {
    my ($platform, $config) = @_;
    log_info("Cleaning up artifacts using hierarchical retention policy");
    my $intervals = $config->{artifacts}{retention}{hierarchical}{intervals} // [];
    my @dirs = (make_path_relative_to_caller($platform->{artifact_dir}), make_path_relative_to_caller('build/archives'));
    for my $dir (@dirs) {
        next unless -d $dir;
        for my $int (@$intervals) {
            my ($period, $keep) = ($int->{period}, $int->{keep});
            my $cutoff = parse_period_to_cutoff($period);
            my @files;
            find(sub { push @files, $File::Find::name if -f $_ }, $dir);
            @files = sort { (stat($b))[9] <=> (stat($a))[9] } @files;
            my $count = 0;
            for my $file (@files) {
                my $mtime = (stat($file))[9];
                if ($mtime < $cutoff) {
                    if ($count >= $keep) {
                        log_info("Deleting old artifact: $file");
                        unlink $file;
                    }
                    $count++;
                }
            }
        }
    }
}

# --- Clean up artifacts using bucketed retention policy ---
# WHAT: Removes artifacts using time-based buckets with configurable retention per bucket
# HOW: Groups files by time intervals, keeps specified number of files per bucket, deletes excess files
# WHY: Provides granular control over artifact retention based on time periods and file counts
# INTERNAL: This is an internal function used by cleanup_old_artifacts_for_platform
sub cleanup_bucketed_retention {
    my ($platform, $config) = @_;
    log_info("Cleaning up artifacts using bucketed retention policy");
    my $buckets = $config->{artifacts}{retention}{bucketed}{buckets} // [];
    my @dirs = (make_path_relative_to_caller($platform->{artifact_dir}), make_path_relative_to_caller('build/archives'));
    for my $dir (@dirs) {
        next unless -d $dir;
        for my $bucket (@$buckets) {
            my ($period, $keep, $keep_count, $keep_interval) = @{$bucket}{qw(period keep keep_count keep_interval)};
            my $cutoff = parse_period_to_cutoff($period);
            my @files;
            find(sub { push @files, $File::Find::name if -f $_ }, $dir);
            @files = sort { (stat($b))[9] <=> (stat($a))[9] } @files;
            my %intervals;
            for my $file (@files) {
                my $mtime = (stat($file))[9];
                next if $mtime > $cutoff;
                my $interval_key = format_interval_key($mtime, $keep_interval);
                push @{$intervals{$interval_key}}, $file;
            }
            for my $interval (keys %intervals) {
                my @bucket_files = @{$intervals{$interval}};
                if ($keep_count && @bucket_files > $keep_count) {
                    for my $file (@bucket_files[$keep_count..$#bucket_files]) {
                        log_info("Deleting old artifact (bucketed): $file");
                        unlink $file;
                    }
                }
            }
        }
    }
}

# --- Convert time period string to Unix timestamp cutoff ---
# WHAT: Converts human-readable time periods (e.g., "7d", "24h") to Unix timestamps for retention calculations
# HOW: Parses period strings with regex, calculates seconds from current time based on period unit
# WHY: Enables flexible retention policy configuration using human-readable time specifications
# INTERNAL: This is an internal utility function used by retention cleanup functions
sub parse_period_to_cutoff {
    my ($period) = @_;
    if ($period =~ /^(\d+)h$/) { return time() - $1 * 3600; }
    if ($period =~ /^(\d+)d$/) { return time() - $1 * 86400; }
    if ($period =~ /^(\d+)w$/) { return time() - $1 * 604800; }
    if ($period =~ /^(\d+)M$/) { return time() - $1 * 2592000; }
    if ($period =~ /^(\d+)y$/) { return time() - $1 * 31536000; }
    return 0;
}

# --- Format file modification time into interval key for bucketing ---
# WHAT: Converts file modification time to a string key representing the time interval for bucketed retention
# HOW: Uses strftime to format timestamp based on interval type (hour/day/week/month/year)
# WHY: Enables grouping of files by time intervals for bucketed retention policies
# INTERNAL: This is an internal utility function used by bucketed retention cleanup
sub format_interval_key {
    my ($mtime, $interval) = @_;
    my @lt = localtime($mtime);
    if ($interval eq 'h') { return strftime('%Y-%m-%d-%H', @lt); }
    if ($interval eq 'd') { return strftime('%Y-%m-%d', @lt); }
    if ($interval eq 'w') { return strftime('%Y-%W', @lt); }
    if ($interval eq 'M') { return strftime('%Y-%m', @lt); }
    if ($interval eq 'y') { return strftime('%Y', @lt); }
    return strftime('%Y-%m-%d', @lt);
}

# --- Validate build configuration for errors and consistency ---
# WHAT: Checks build configuration for duplicate names, missing required fields, and schema compliance
# HOW: Scans tasks, platforms, and groups for duplicates, validates required fields, reports all errors
# WHY: Catches configuration errors early to prevent build failures and ensure consistent configuration
# PUBLIC: This function is part of the public API and can be used by build scripts for validation
# --- Validate array fields for empty arrays ---
# WHAT: Checks for empty array fields that should contain values
# HOW: Validates notification fields, dependencies, and other array fields across all config sections
# WHY: Prevents runtime errors from empty arrays that should contain data
# PUBLIC: This function is used by validate_config, not intended for direct use
sub validate_array_fields {
    my ($cfg, $errors_ref) = @_;
    
    # Check notification fields in tasks
    for my $task (@{$cfg->{tasks} // []}) {
        my $name = $task->{name};
        for my $notif_field (qw(notifies notifies_on_success notifies_on_failure)) {
            if (exists $task->{$notif_field}) {
                if (ref($task->{$notif_field}) eq 'ARRAY' && @{$task->{$notif_field}} == 0) {
                    push @$errors_ref, "Task '$name' has empty $notif_field array - remove the field or add entries";
                } elsif (ref($task->{$notif_field}) ne 'ARRAY' && ref($task->{$notif_field}) ne 'HASH') {
                    push @$errors_ref, "Task '$name' has invalid $notif_field field - must be array or hash";
                }
            }
        }
    }
    
    # Check notification fields in platforms
    for my $platform (@{$cfg->{platforms} // []}) {
        my $name = $platform->{name};
        for my $notif_field (qw(notifies notifies_on_success notifies_on_failure)) {
            if (exists $platform->{$notif_field}) {
                if (ref($platform->{$notif_field}) eq 'ARRAY' && @{$platform->{$notif_field}} == 0) {
                    push @$errors_ref, "Platform '$name' has empty $notif_field array - remove the field or add entries";
                } elsif (ref($platform->{$notif_field}) ne 'ARRAY' && ref($platform->{$notif_field}) ne 'HASH') {
                    push @$errors_ref, "Platform '$name' has invalid $notif_field field - must be array or hash";
                }
            }
        }
    }
    
    # Check notification fields in build groups
    for my $gname (keys %{$cfg->{build_groups} // {}}) {
        my $group = $cfg->{build_groups}{$gname};
        for my $notif_field (qw(notifies notifies_on_success notifies_on_failure)) {
            if (exists $group->{$notif_field}) {
                if (ref($group->{$notif_field}) eq 'ARRAY' && @{$group->{$notif_field}} == 0) {
                    push @$errors_ref, "Build group '$gname' has empty $notif_field array - remove the field or add entries";
                } elsif (ref($group->{$notif_field}) ne 'ARRAY' && ref($group->{$notif_field}) ne 'HASH') {
                    push @$errors_ref, "Build group '$gname' has invalid $notif_field field - must be array or hash";
                }
            }
        }
    }
    
    # Check other array fields that should not be empty
    for my $task (@{$cfg->{tasks} // []}) {
        my $name = $task->{name};
        for my $array_field (qw(dependencies requires_execution_of)) {
            if (exists $task->{$array_field}) {
                if (ref($task->{$array_field}) eq 'ARRAY' && @{$task->{$array_field}} == 0) {
                    push @$errors_ref, "Task '$name' has empty $array_field array - remove the field or add entries";
                } elsif (ref($task->{$array_field}) ne 'ARRAY') {
                    push @$errors_ref, "Task '$name' has invalid $array_field field - must be array";
                }
            }
        }
    }
    
    for my $platform (@{$cfg->{platforms} // []}) {
        my $name = $platform->{name};
        for my $array_field (qw(dependencies requires_execution_of)) {
            if (exists $platform->{$array_field}) {
                if (ref($platform->{$array_field}) eq 'ARRAY' && @{$platform->{$array_field}} == 0) {
                    push @$errors_ref, "Platform '$name' has empty $array_field array - remove the field or add entries";
                } elsif (ref($platform->{$array_field}) ne 'ARRAY') {
                    push @$errors_ref, "Platform '$name' has invalid $array_field field - must be array";
                }
            }
        }
    }
}

sub validate_config {
    my ($cfg) = @_;
    my %seen;
    my @errors;
    # Check for duplicate task names
    for my $task (@{$cfg->{tasks} // []}) {
        my $name = $task->{name};
        if ($seen{task}{$name}++) {
            push @errors, "Duplicate task name: $name";
        }
    }
    # Check for duplicate platform names
    for my $plat (@{$cfg->{platforms} // []}) {
        my $name = $plat->{name};
        if ($seen{platform}{$name}++) {
            push @errors, "Duplicate platform name: $name";
        }
    }
    # Check for duplicate group names
    for my $gname (keys %{$cfg->{build_groups} // {}}) {
        if ($seen{group}{$gname}++) {
            push @errors, "Duplicate build group name: $gname";
        }
    }
    # Schema validation: check required fields for platforms
    for my $plat (@{$cfg->{platforms} // []}) {
        for my $field (qw(name artifact_dir artifact_patterns build_command)) {
            push @errors, "Platform missing required field: $field" unless defined $plat->{$field};
        }
    }
    # Schema validation: check required fields for tasks
    for my $task (@{$cfg->{tasks} // []}) {
        push @errors, "Task missing required field: name" unless defined $task->{name};
        push @errors, "Task missing required field: command" unless defined $task->{command};
    }
    # Schema validation: check required fields for build groups
    for my $gname (keys %{$cfg->{build_groups} // {}}) {
        my $group = $cfg->{build_groups}{$gname};
        push @errors, "Build group '$gname' missing required field: targets" unless defined $group->{targets};
        # Do not iterate or dereference targets here
    }
    
    # Enhanced validation: check for empty array fields
    validate_array_fields($cfg, \@errors);
    
    if (@errors) {
        log_error($_) for @errors;
        die "Config validation failed. See errors above.\n";
    } else {
        log_success("Config schema validation passed.");
    }
}

# --- Get configuration value with default fallback ---
# WHAT: Retrieves a configuration value from the configurations section with optional default
# HOW: Looks up key in configurations hash, returns default if key not found
# WHY: Provides safe access to configuration values with sensible defaults
# PUBLIC: This function is part of the public API and can be used by build scripts
sub get_config_value {
    my ($cfg, $key, $default) = @_;
    return $cfg->{configurations}{$key} // $default;
}

# --- Interpolate variables in strings using argument hash ---
# WHAT: Replaces variable placeholders (${var}) in strings with values from argument hash
# HOW: Uses regex substitution to replace ${var} patterns with corresponding hash values
# WHY: Enables dynamic string generation for commands, paths, and other configurable values
# PUBLIC: This function is part of the public API and can be used by build scripts
sub interpolate_name {
    my ($name, $args) = @_;
    # Ensure $args is always a hashref before dereferencing
    if (!ref($args) || ref($args) ne 'HASH') {
        log_warn("interpolate_name: args is not a hashref for '$name', got: " . (defined $args ? $args : 'undef'));
        return $name;
    }
    $name =~ s/\$\{(\w+)\}/exists $args->{$1} ? $args->{$1} : ""/ge;
    return $name;
}

# --- Extract global variables for command argument expansion ---
# Global variables are used for string interpolation in commands and argument substitution
# DEPRECATED: Use BuildUtils::extract_global_vars instead
# This function is kept for backward compatibility but should not be used
# The unified version in BuildUtils.pm handles both global_vars array and top-level variables
sub extract_global_vars {
    my ($cfg) = @_;
    my %reserved = map { $_ => 1 } (
        'tasks', 'platforms', 'build_groups', 'logging', 'exclude_from_globals',
        'name', 'args', 'command', 'type', 'dependencies', 'children'
    );
    my @exclude = @{$cfg->{exclude_from_globals} // []};
    $reserved{$_} = 1 for @exclude;
    my %globals;
    for my $k (keys %$cfg) {
        next if $reserved{$k};
        if (ref($cfg->{$k}) eq 'HASH' && exists $cfg->{$k}{default}) {
            $globals{$k} = $cfg->{$k}{default};
        } else {
            $globals{$k} = $cfg->{$k};
        }
    }
    
    return \%globals;
}

# # --- Build the execution tree with fully expanded nodes ---
# sub process_targets {
#     my ($cfg, $target_name, $parent_args, $visited, $registry) = @_;
#     $parent_args = {} unless ref($parent_args) eq "HASH";
#     $visited ||= {};
#     die "process_targets requires a BuildNodeRegistry" unless ref($registry) && $registry->can('get_node');
#     my $interpolated_name = interpolate_name($target_name, $parent_args);
#     return if $visited->{$interpolated_name}++;
# 
#     # Key for this node (name + args)
#     my $key;
#     my $obj;
# 
#     # Platform node
#     if (my ($plat) = grep { $_->name eq $interpolated_name } @{ $cfg->{platforms} // [] }) {
#         my %node = %{$plat};
#         $node{type} = 'platform';
#         $node{args} = { %$parent_args };
#         $obj = BuildNode->new(%node);
#         $key = $obj->key;
#         return $registry->get_node($key) if $registry->has_node($key);
#         $registry->add_node($obj);
#         $obj->{children} ||= [];
#         $obj->{dependencies} ||= [];
#         # --- Resolve and attach dependencies ---
#         if (exists $plat->{dependencies} && ref $plat->{dependencies} eq 'ARRAY') {
#             for my $dep_name (@{ $plat->{dependencies} }) {
#                 my $dep_node = process_targets($cfg, $dep_name, {}, $visited, $registry);
#                 $obj->add_dependency($dep_node) if $dep_node;
#             }
#         }
#         if (exists $plat->{notifies} && ref $plat->{notifies} eq 'ARRAY') {
#             for my $notify (@{ $plat->{notifies} }) {
#                 my $notify_name = ref($notify) eq 'HASH' ? $notify->{name} : $notify;
#                 my $notify_node = process_targets($cfg, $notify_name, {}, $visited, $registry);
#                 $obj->add_notify($notify_node) if $notify_node;
#             }
#         }
#         return $obj;
#     }
#     # Task node
#     if (my ($task) = grep { $_->name eq $interpolated_name } @{ $cfg->{tasks} // [] }) {
#         my %node = %{$task};
#         $node{type} = 'task';
#         $node{args} = { %$parent_args };
#         $obj = BuildNode->new(%node);
#         $key = $obj->key;
#         return $registry->get_node($key) if $registry->has_node($key);
#         $registry->add_node($obj);
#         $obj->{children} ||= [];
#         $obj->{dependencies} ||= [];
#         # --- Resolve and attach dependencies ---
#         if (exists $task->{dependencies} && ref $task->{dependencies} eq 'ARRAY') {
#             for my $dep_name (@{ $task->{dependencies} }) {
#                 my $dep_node = process_targets($cfg, $dep_name, {}, $visited, $registry);
#                 $obj->add_dependency($dep_node) if $dep_node;
#             }
#         }
#         if (exists $task->{notifies} && ref $task->{notifies} eq 'ARRAY') {
#             for my $notify (@{ $task->{notifies} }) {
#                 my $notify_name = ref($notify) eq 'HASH' ? $notify->{name} : $notify;
#                 my $notify_node = process_targets($cfg, $notify_name, {}, $visited, $registry);
#                 $obj->add_notify($notify_node) if $notify_node;
#             }
#         }
#         return $obj;
#     }
#     # Group node
#     if (my $group = $cfg->{build_groups}{$interpolated_name}) {
#         my @children;
#         my $targets = $group->{targets};
#         if (ref $targets ne 'ARRAY') {
#             $targets = [];
#         }
#         for my $tgt (@$targets) {
#             my ($name, $args, $requires_execution_of);
#             if (ref $tgt eq 'HASH') {
#                 $name = $tgt->{name};
#                 $args = $tgt->{args};
#                 $requires_execution_of = $tgt->{requires_execution_of};
#             } else {
#                 $name = $tgt;
#                 $args = undef;
#                 $requires_execution_of = undef;
#             }
#             my $merged_args = merge_args($parent_args, $args);
#             my $child = process_targets($cfg, $name, $merged_args, $visited, $registry);
#             if ($child && $requires_execution_of) {
#                 $child->{requires_execution_of} = $requires_execution_of;
#             }
#             push @children, $child if $child;
#         }
#         my %node = (
#             name => $interpolated_name,
#             type => 'group',
#             args => { %$parent_args },
#             children => \@children,
#             continue_on_error => $group->{continue_on_error} // $cfg->{continue_on_error} // 0,
#         );
#         $obj = BuildNode->new(%node);
#         $key = $obj->key;
#         return $registry->get_node($key) if $registry->has_node($key);
#         $registry->add_node($obj);
#         $obj->{children} ||= [];
#         $obj->{dependencies} ||= [];
#         # --- Resolve and attach dependencies ---
#         if (exists $group->{dependencies} && ref $group->{dependencies} eq 'ARRAY') {
#             for my $dep_name (@{ $group->{dependencies} }) {
#                 my $dep_node = process_targets($cfg, $dep_name, {}, $visited, $registry);
#                 $obj->add_dependency($dep_node) if $dep_node;
#             }
#         }
#         if (exists $group->{notifies} && ref $group->{notifies} eq 'ARRAY') {
#             for my $notify (@{ $group->{notifies} }) {
#                 my $notify_name = ref($notify) eq 'HASH' ? $notify->{name} : $notify;
#                 my $notify_node = process_targets($cfg, $notify_name, {}, $visited, $registry);
#                 $obj->add_notify($notify_node) if $notify_node;
#             }
#         }
#         return $obj;
#     }
#     return;
# }

# --- Print summary from tree ---
sub print_tree_summary {
    my ($tree) = @_;
    my (%platforms, %tasks, %groups, %platform_nodes, %task_nodes, %group_nodes);
    $tree->traverse(sub {
        my $node = shift;
        if ($node->is_platform) {
            $platforms{$node->name} = 1;
            $platform_nodes{$node->name} = $node;
        } elsif ($node->is_task) {
            $tasks{$node->name} = 1;
            $task_nodes{$node->name} = $node;
        } elsif ($node->is_group) {
            $groups{$node->name} = 1;
            $group_nodes{$node->name} = $node;
        }
    });
    print "\nAvailable Platforms:\n";
    print "  - ", format_node($platform_nodes{$_}, 'default'), "\n" for sort keys %platforms;
    print "\nAvailable Tasks:\n";
    print "  - ", format_node($task_nodes{$_}, 'default'), "\n" for sort keys %tasks;
    print "\nAvailable Build Groups:\n";
    print "  - ", format_node($group_nodes{$_}, 'default'), "\n" for sort keys %groups;
        print "\n";
}

# --- Unified Tree Print Function ---
sub print_tree {
    my ($root, $graph, $all_nodes, $opts) = @_;
    $opts ||= {};
    my $show_notifications = $opts->{show_notifications} // 0;
    my %seen;
    my $print_tree;
    $print_tree = sub {
        my ($node, $prefix) = @_;
        my $key = get_key_from_node($node);
        return if $seen{$key}++;
        print $prefix . format_node($node, 'default') . "\n";
        unless ($node->is_leaf) {
            for my $child (@{ $node->children }) {
                $print_tree->($child, $prefix . "  ");
            }
        }
        if ($show_notifications && $graph && $graph->{$key} && $graph->{$key}->{notifies}) {
            for my $notified_key (@{ $graph->{$key}->{notifies} }) {
                my $notified_node = get_node_by_key($notified_key, $all_nodes);
                next unless $notified_node;
                print $prefix . "  (notifies) ";
                $print_tree->($notified_node, $prefix . "    ");
            }
        }
    };
    $print_tree->($root, "");
    # Print orphaned notified tasks (not in main tree)
    if ($show_notifications) {
        for my $key (sort keys %$all_nodes) {
            next if $seen{$key};
            print "(notified, not in main tree) ", format_node($all_nodes->{$key}, 'default'), "\n";
            unless ($all_nodes->{$key}->is_leaf) {
                $print_tree->($all_nodes->{$key}, "");
            }
        }
    }
}

# --- Print Declared Order (Group/Target Hierarchy) ---
sub print_declared_order {
    my ($cfg, $target, $prefix, $parent_args) = @_;
    $prefix ||= '';
    $parent_args ||= undef;
    print "$prefix$target";
    if ($parent_args && ref $parent_args eq 'HASH' && %$parent_args) {
        print " [" . join(", ", map { "$_=$parent_args->{$_}" } sort keys %$parent_args) . "]";
    }
    print "\n";
    return unless exists $cfg->{build_groups}{$target};
    my $group = $cfg->{build_groups}{$target};
    for my $tgt (@{$group->{targets} // []}) {
        my ($name, $args, $notifies, $requires_execution_of, $instance, $notify_on_success, $notify_on_failure) = extract_target_info($tgt);
        # Simple argument merging without using the old merge_args pattern
        my %merged_args = %{ $parent_args // {} };
        if ($args && ref $args eq 'HASH') {
            %merged_args = (%merged_args, %$args);
        }
        print_declared_order($cfg, $name, "$prefix  ", \%merged_args);
    }
}




# --- Validation using process_targets ---
sub validate_tree {
    my ($node, $errors) = @_;
    $errors ||= [];
    $| = 1; # autoflush
    use Data::Dumper;
    log_debug("validate_tree: EARLY node dump:\n" . Dumper($node));
    unless (ref $node && $node->can('name') && $node->can('type') && $node->can('children')) {
        log_debug("validate_tree: node is not a hashref or missing keys. Skipping. Node: " . (defined $node ? $node : 'undef') . "\n");
        return $errors;
    }
    # Defensive: check children is an arrayref
    my $children = $node->children;
    unless (ref $children eq 'ARRAY') {
        log_error("validate_tree: Node '" . $node->name . "' children is not an arrayref. Type: " . ref($children) . ", Value: " . Dumper($children));
        return $errors;
    }
    # Validate this node's arguments using the centralized method
    handle_result_hash($node->validate_args, $errors);
    # Validate children
    for my $child (@$children) {
        unless (ref $child && $child->can('name')) {
            log_error("validate_tree: Child of node '" . $node->name . "' is not a BuildNode. Type: " . ref($child) . ", Value: " . Dumper($child));
            next;
        }
        validate_tree($child, $errors);
    }
    return $errors;
}

# --- Build order using process_targets ---
sub build_order_list {
    my ($node, $order, $seen) = @_;
    $order ||= [];
    $seen ||= {};
    traverse_nodes($node, sub { push @$order, $_[0]->{name} unless $seen->{$_[0]->{name}}++ }, $seen);
    return $order;
}

# REMOVED: execute_dependencies function - legacy architecture replaced by three-queue system
# Dependencies are now handled automatically by Phases 1 and 2 (coordination)

# --- Helper Functions (Top Level) ---

# --- Helper function to get all available targets ---
# WHAT: Discovers all available targets using the same logic as --list-targets
# HOW: Reuses the exact target discovery code from the list-targets implementation
# WHY: Ensures consistency between listing and validation, follows DRY principles
# PUBLIC: This function can be called independently for target discovery
sub get_all_available_targets {
    my ($cfg) = @_;
    my @all_targets = ();
    
    # Use the exact same logic as --list-targets
    for my $platform (@{$cfg->{platforms} // []}) {
        push @all_targets, $platform->{name};
    }
    
    for my $task (@{$cfg->{tasks} // []}) {
        push @all_targets, $task->{name};
    }
    
        for my $group (sort keys %{$cfg->{build_groups} // {}}) {
        push @all_targets, $group;
    }
    
    return sort @all_targets;
}

# --- Helper function to get target details ---
# WHAT: Collects detailed information about all targets for consistent display
# HOW: Builds a hash of target details that can be used by both listing and validation
# WHY: Ensures consistent target information across all functions, follows DRY principles
# PUBLIC: This function can be called independently for target detail collection
sub get_target_details {
    my ($cfg) = @_;
    my %details = ();
    
    # Collect platform details
    for my $platform (@{$cfg->{platforms} // []}) {
        $details{$platform->{name}} = {
            description => $platform->{description} || "",
            type => "platform"
        };
    }
    
    # Collect task details
    for my $task (@{$cfg->{tasks} // []}) {
        $details{$task->{name}} = {
            description => $task->{description} || "",
            args => $task->{args} || {},
            type => "task"
        };
    }
    
    # Collect build group details
    for my $group (sort keys %{$cfg->{build_groups} // {}}) {
        my $group_config = $cfg->{build_groups}->{$group};
        $details{$group} = {
            description => $group_config->{description} || "",
            type => "group"
        };
    }
    
    return %details;
}

# --- Target validation and help function ---
# WHAT: Validates a target exists and provides helpful suggestions if not found
# HOW: Checks target existence and displays appropriate help messages
# WHY: Centralizes target validation logic and provides consistent user experience
# PUBLIC: This function can be called independently for target validation
sub validate_target_and_show_help {
    my ($target_name, $cfg) = @_;
    
    my ($target_exists, $suggestion) = validate_target_with_suggestions($target_name, $cfg);
    unless ($target_exists) {
        log_error("Target '$target_name' not found in build configuration.");
        if ($suggestion) {
            log_error($suggestion);
        }
        
        # Provide additional help
        log_error("\nTo see all available targets, run: ./Scripts/build.pl --list-targets");
        log_error("To see build order for a specific target, run: ./Scripts/build.pl --target <target> --dry-run");
        
        exit 1;
    }
}

# --- Configuration validation function ---
# WHAT: Validates all build groups in the configuration by building trees and checking for errors
# HOW: Iterates through build groups, builds trees, and validates them
# WHY: Provides centralized validation logic that can be reused across all execution modes
# PUBLIC: This function can be called independently for configuration validation
sub validate_configuration {
    my ($cfg) = @_;
    
    log_info("Validating configuration...");
        my $errors = [];
    
        for my $group (sort keys %{$cfg->{build_groups} // {}}) {
            my $global_defaults = extract_global_vars($cfg);
        my ($registry, $tree) = build_tree_for_group($group, $cfg, $global_defaults);
            my $errs = validate_tree($tree);
            push @$errors, @$errs if $errs && @$errs;
        }
    
        if (@$errors) {
            log_error($_) for @$errors;
            die "Config validation failed. See errors above.\n";
        } else {
            log_success("Config validation passed.");
        }
    }
    
# --- Main Function ---

# --- Consolidated execution function to eliminate duplicate code ---
# WHAT: Handles all execution modes (target, display, default) through a single code path
# HOW: Determines execution mode from CLI flags and calls the unified execution engine
# WHY: Eliminates ~100 lines of duplicate code across three execution paths
# PUBLIC: This is the primary execution interface for all build modes
# NOTE: This function is currently unused - commented out to avoid confusion
# sub execute_target_with_validation {
#     my ($target_name, $cfg, $execution_mode) = @_;
#     
#     # Validate configuration if requested
#     if ($cfg->{validate_on_build}) {
#         validate_configuration($cfg);
#     }
#     
#     # Validate target and provide suggestions if not found
#     validate_target_and_show_help($target_name, $cfg);
#     
#     # Use notification-driven execution for all targets
#     my $registry = BuildNodeRegistry->new;
#     my $global_defaults = extract_global_vars($cfg);
#     my $tree = build_graph_with_worklist($target_name, {}, $cfg, $global_defaults, $registry);
#     $registry->build_from_tree($tree);
#     
#     # Use the unified execution engine
#     my ($result, $execution_order_ref, $duration_ref) = execute_build_nodes($registry);
#     
#     # Display summary after execution (unless --no-summary is specified, or force with --summary)
#     if (!$no_summary || $summary) {
#         print_build_summary($execution_order_ref, $duration_ref, $registry);
#     }
#     
#     return ($result, $execution_order_ref, $duration_ref);
# }

# --- Queue Management Functions (for unified execution) ---
# WHAT: Functions to manage the three-queue system used by the execution engine
# HOW: Provide clean interfaces for queue operations
# WHY: Centralizes queue management logic and ensures consistent behavior
# PUBLIC: These functions are used by the unified execution path

# has_ready_nodes is now in BuildUtils.pm

# get_eligible_pending_parent_nodes is now in BuildUtils.pm

# get_eligible_groups_ready_nodes is now in BuildUtils.pm

# get_next_ready_node is now in BuildUtils.pm

# remove_from_ready_queue is now in BuildUtils.pm

# remove_from_groups_ready is now in BuildUtils.pm
# --- Validation Output for Notification Graph ---
sub validate_notification_graph {
    my ($registry) = @_;
            log_info("Notification Graph (task[|args] -> notified tasks):");
    my $has_error = 0;
    for my $pair (enumerate_notifications($REGISTRY)) {
        my ($node, $unconditional, $success, $failure) = @$pair;
        my @all_notified = (@$unconditional, @$success, @$failure);
        log_verbose("  " . $node->key . " -> " . join(", ", map { $_->key } @all_notified));
        for my $notified (@all_notified) {
            unless ($notified) {
                log_error("Notification from '" . $node->key . "' to undefined target");
                $has_error = 1;
            }
        }
    }
    # Optionally, output DOT/mermaid for visualization
    if ($VERBOSITY_LEVEL >= 2) {
        print "\nDOT/mermaid graph (for visualization):\n";
        print "graph TD;\n";
        for my $pair (enumerate_notifications($REGISTRY)) {
            my ($node, $unconditional, $success, $failure) = @$pair;
            my @all_notified = (@$unconditional, @$success, @$failure);
            for my $notified (@all_notified) {
                print "  \"", $node->key, "\" --> \"", $notified->key, "\"\n";
            }
        }
    }
    if ($has_error) {
        die "Validation failed: one or more notifications point to undefined tasks or argument sets.\n";
    }
}

sub check_node_ready_buildnode {
    my ($node, $node_status_ref, $node_dependencies_ref, $groups_ready_nodes_ref) = @_;
    return 0 unless $node;
    
    log_debug("check_node_ready_buildnode: checking " . $node->name);
    
    # 1. Check if node's own dependencies succeeded
    my $deps_ok = check_dependencies_succeeded_buildnode($node, $node_dependencies_ref, $node_status_ref);
    log_debug("check_node_ready_buildnode: " . $node->name . " dependencies check result: " . ($deps_ok ? "PASSED" : "FAILED"));
    if (!$deps_ok) {
        log_debug("check_node_ready_buildnode: " . $node->name . " is NOT ready (dependencies failed)");
        return 0;
    }
    
    # 2. Check if any parent group is ready (OR logic)
    my $parent_ready = check_parent_group_ready_buildnode($node, $groups_ready_nodes_ref, $node_status_ref);
    log_debug("check_node_ready_buildnode: " . $node->name . " parent group check result: " . ($parent_ready ? "PASSED" : "FAILED"));
    if (!$parent_ready) {
        log_debug("check_node_ready_buildnode: " . $node->name . " is NOT ready (no parents ready)");
        return 0;
    }
    
    # 3. Check if node is blocked by other nodes
    my $not_blocked = check_node_not_blocked_buildnode($node, $node_status_ref);
    log_debug("check_node_ready_buildnode: " . $node->name . " blocked check result: " . ($not_blocked ? "PASSED" : "FAILED"));
    if (!$not_blocked) {
        log_debug("check_node_ready_buildnode: " . $node->name . " is NOT ready (blocked by other nodes)");
        return 0;
    }
    
    # 4. Check if notification dependencies are satisfied (using BuildNode internal fields)
    my $notifications_ok = check_notifications_succeeded_buildnode($node, $node_status_ref);
    log_debug("check_node_ready_buildnode: " . $node->name . " notifications check result: " . ($notifications_ok ? "PASSED" : "FAILED"));
    if (!$notifications_ok) {
        log_debug("check_node_ready_buildnode: " . $node->name . " is NOT ready (notification dependencies not satisfied)");
        return 0;
    }
    
    log_debug("check_node_ready_buildnode: " . $node->name . " is READY to execute");
    return 1;
}
    
    sub transition_node {
	my ($node_key, $new_status, $registry, $status_ref) = @_;
        my $node = $registry->get_node_by_key($node_key);
	$STATUS_MANAGER->set_status($node, $new_status);
        $status_ref->{$node_key} = $new_status;
        
        # Clean up blocked_by relationships when node completes
        if ($new_status eq 'done' || $new_status eq 'skipped' || $new_status eq 'failed') {
            if ($node && $node->can('get_blocked_nodes')) {
                my @blocked_nodes = $node->get_blocked_nodes();
                for my $blocked_key (@blocked_nodes) {
                    my $blocked_node = $registry->get_node_by_key($blocked_key);
                    if ($blocked_node) {
                        $blocked_node->remove_blocker($node);
                        log_debug("Removed blocker $node_key from $blocked_key");
                    }
                }
            }
        }
        
        # Process notifications when node completes (including validate mode)
        if (is_successful_completion_status($new_status)) {
            # Node succeeded, process notify_on_success notifications
            if ($node && $node->can('get_notifies_on_success')) {
                my @notify_targets = @{ $node->get_notifies_on_success() || [] };
                for my $target (@notify_targets) {
                    if (defined($target) && ref($target) eq 'HASH' && defined($target->{name})) {
                        my $target_name = $target->{name};
                        log_debug("transition_node: $node_key successfully completed with status '$new_status', notifying $target_name");
                        # In validate mode, this notification will allow dependent nodes to proceed
                    }
                }
            }
        } elsif ($new_status eq 'failed') {
            # Node failed, process notify_on_failure notifications
            if ($node && $node->can('get_notifies_on_failure')) {
                my @notify_targets = @{ $node->get_notifies_on_failure() || [] };
                for my $target (@notify_targets) {
                    if (defined($target) && ref($target) eq 'HASH' && defined($target->{name})) {
                        my $target_name = $target->{name};
                        log_debug("transition_node: $node_key failed with status '$new_status', notifying $target_name");
                        # In validate mode, this notification will allow dependent nodes to proceed
                    }
                }
            }
        }
    }
    
    sub transition_node_buildnode {
	my ($node, $new_status, $node_status_ref, $registry) = @_;
	
	log_debug("transition_node_buildnode called for node: " . ($node ? $node->name : 'undefined') . ", new_status: $new_status");
	
	$STATUS_MANAGER->set_status($node, $new_status);
        
        # Clean up blocked_by relationships when node completes
        if ($new_status eq 'done' || $new_status eq 'skipped' || $new_status eq 'failed') {
            if ($node && $node->can('get_blocked_nodes')) {
                my @blocked_nodes = $node->get_blocked_nodes();
                for my $blocked_key (@blocked_nodes) {
                    my $blocked_node = $registry->get_node_by_key($blocked_key);
                    if ($blocked_node) {
                        $blocked_node->remove_blocker($node);
                        log_debug("Removed blocker " . $node->name . " from " . $blocked_node->name);
                    }
                }
            }
        }
        
        # Process conditional notifications using the new array-based system
        # When a node completes, update all nodes that are waiting for it
        if ($node && $node->can('get_notifies')) {
            my @notify_targets = @{ $node->get_notifies() || [] };
            log_debug("transition_node_buildnode: " . $node->name . " has " . scalar(@notify_targets) . " unconditional notification targets");
            for my $target_node (@notify_targets) {
                if ($target_node) {
                    # Unconditional notifications are always sent regardless of success/failure
                    log_debug("transition_node_buildnode: " . $node->name . " completed, sending unconditional notification to " . $target_node->name);
                    # For unconditional notifications, we could add them to a special array or handle them differently
                    # For now, we'll just log them since they don't affect conditional logic
                }
            }
        }

        if ($node && $node->can('get_notifies_on_success')) {
            my @notify_targets = @{ $node->get_notifies_on_success() || [] };
            log_debug("transition_node_buildnode: " . $node->name . " has " . scalar(@notify_targets) . " success notification targets");
            for my $target_node (@notify_targets) {
                if ($target_node) {
                    if (is_successful_completion_status($new_status)) {
                        # Node succeeded, mark as true in target's success_notify array
                        log_debug("transition_node_buildnode: " . $node->name . " succeeded, updating success_notify for " . $target_node->name);
                        $target_node->update_success_notify($node, 1);  # Mark as true
                    } else {
                        # Node failed, mark as false in target's success_notify array
                        log_debug("transition_node_buildnode: " . $node->name . " failed, updating success_notify for " . $target_node->name);
                        $target_node->update_success_notify($node, 0);  # Mark as false
                    }
                }
            }
        }

        if ($node && $node->can('get_notifies_on_failure')) {
            my @notify_targets = @{ $node->get_notifies_on_failure() || [] };
            log_debug("transition_node_buildnode: " . $node->name . " has " . scalar(@notify_targets) . " failure notification targets");
            for my $target_node (@notify_targets) {
                if ($target_node) {
                    if ($new_status eq 'failed') {
                        # Node failed, mark as true in target's failure_notify array
                        log_debug("transition_node_buildnode: " . $node->name . " failed, updating failure_notify for " . $target_node->name);
                        $target_node->update_failure_notify($node, 1);  # Mark as true
                    } else {
                        # Node succeeded, mark as false in target's failure_notify array
                        log_debug("transition_node_buildnode: " . $node->name . " succeeded, updating failure_notify for " . $target_node->name);
                        $target_node->update_failure_notify($node, 0);  # Mark as false
                    }
                }
            }
        }
    }
    
    sub check_dependencies_succeeded_buildnode {
	my ($node, $node_dependencies_ref, $node_status_ref) = @_;
        return 1 unless $node;
        
        my @deps = @{$node_dependencies_ref->{$node} // []};
        log_debug("check_dependencies_succeeded_buildnode: " . $node->name . " has " . scalar(@deps) . " dependencies");
        for my $dep (@deps) {
            my $dep_status = $node_status_ref->{$dep} // 'undefined';
            log_debug("check_dependencies_succeeded_buildnode: dependency " . $dep->name . " has status: " . $dep_status);
            return 0 unless is_successful_completion_status($dep_status);
        }
        return 1;
    }
    
    sub check_parent_group_ready_buildnode {
        my ($node, $groups_ready_nodes_ref, $node_status_ref) = @_;
        return 1 unless $node; # No node found, assume ready
        
        # Check if this is a root node (no parents) - root nodes are always ready
        if ($node->can('get_parents')) {
            my @parents = $node->get_parents();
            if (@parents == 0) {
                log_debug("check_parent_group_ready_buildnode: " . $node->name . " is a root node (no parents), always ready");
                return 1;
            }
        }
        
        # Check if any parent is in groups_ready AND respects continue_on_error logic
        for my $parent ($node->get_parents()) {
            # Check if parent is in groups_ready
            if (exists $groups_ready_nodes_ref->{$parent}) {
                log_debug("check_parent_group_ready_buildnode: " . $node->name . " has parent " . $parent->name . " in groups_ready");
                
                # If parent has continue_on_error = false, check its status
                if (defined($parent->continue_on_error) && !$parent->continue_on_error) {
                    # Strict parent (coe = false) must be in successful state to coordinate
                    my $parent_status = $node_status_ref->{$parent};
                    if (!is_successful_completion_status($parent_status)) {
                        log_debug("check_parent_group_ready_buildnode: " . $node->name . " parent " . $parent->name . " has coe=false and status '$parent_status', not ready");
                        next; # Try next parent
            } else {
                        log_debug("check_parent_group_ready_buildnode: " . $node->name . " parent " . $parent->name . " has coe=false and successful status '$parent_status', ready");
                        return 1;
                    }
                } else {
                    # Forgiving parent (coe = true or undefined) can coordinate regardless of status
                    log_debug("check_parent_group_ready_buildnode: " . $node->name . " parent " . $parent->name . " has coe=true or undefined, ready");
                    return 1;
                }
            }
        }
        
        log_debug("check_parent_group_ready_buildnode: " . $node->name . " no parents ready (either not in groups_ready or strict parents failed)");
        return 0;
    }
    
    sub check_node_not_blocked_buildnode {
        my ($node, $node_status_ref) = @_;
        return 1 unless $node; # No node found, assume not blocked
        
        # Check if this node is blocked by any other nodes
        my @blockers = $node->get_blockers();
        if ($VERBOSITY_LEVEL >= 3) {
            if (@blockers > 0) {
                log_debug("check_node_not_blocked_buildnode: " . $node->name . " has " . scalar(@blockers) . " blockers: " . join(", ", map { $_->name } @blockers));
            }
        }
        
        for my $blocker (@blockers) {
            # A node is blocked if any of its blockers are not 'done' or 'skipped'
            my $blocker_status = $node_status_ref->{$blocker} // 'undefined';
            if (!exists $node_status_ref->{$blocker} || 
                !is_successful_completion_status($blocker_status)) {
                log_debug("check_node_not_blocked_buildnode: " . $node->name . " is BLOCKED by " . $blocker->name . " (status: " . ($blocker_status // 'undefined') . ")");
                return 0;
            }
        }
        
        if (@blockers > 0) {
            log_debug("check_node_not_blocked_buildnode: " . $node->name . " is NOT blocked (all blockers done/skipped)");
        }
        return 1; # No blockers, or all blockers are done/skipped
    }
    
    sub check_notifications_succeeded_buildnode {
	my ($node, $node_status_ref) = @_;
        
            # Use the new conditional notification system
            if ($node->conditional) {
                my $success_state = $node->all_success_conditions_met;
                my $failure_state = $node->all_failure_conditions_met;
                
                # Debug output
                my $success_array = $node->success_notify;
                my $failure_array = $node->failure_notify;
                log_debug("Node " . $node->name . " conditional check:");
                log_debug("  success_notify: " . scalar(@$success_array) . " entries");
                log_debug("  failure_notify: " . scalar(@$failure_array) . " entries");
                log_debug("  success_state: " . ($success_state == 1 ? "met" : $success_state == 0 ? "not-met" : "not-run"));
                log_debug("  failure_state: " . ($failure_state == 1 ? "met" : $failure_state == 0 ? "not-met" : "not-run"));
                
                # Node runs if:
                # 1. All notifications have happened (no -1 in either array)
                # 2. AND (success conditions are met OR failure conditions are met)
                my $all_notifications_complete = ($success_state != -1) && ($failure_state != -1);
                my $conditions_met = ($success_state == 1) || ($failure_state == 1);
                
                log_debug("  all_notifications_complete: " . ($all_notifications_complete ? "true" : "false"));
                log_debug("  conditions_met: " . ($conditions_met ? "true" : "false"));
                
                return $all_notifications_complete && $conditions_met;
            }
        
        # Fallback to old system for non-conditional nodes
        my @notifiers = $node->get_notified_by;
        for my $notifier (@notifiers) {
            my $notifier_status = $node_status_ref->{$notifier} // 'undefined';
            return 0 unless is_successful_completion_status($notifier_status);
        }
        return 1;
    }
    
    sub process_ready_pending_parent_buildnode {
	my ($registry, $groups_ready_nodes_ref, $ready_queue_nodes_ref, $ready_pending_parent_nodes_ref, $status_ref) = @_;
        my $moved_count = 0;
        
        # FIRST PASS: Copy structurally ready tasks to groups_ready (they stay in rpp)
        for my $node (@$ready_pending_parent_nodes_ref) {
            next unless $node;
            
            # Check if this node is structurally ready (no external dependencies)
            if ($node->can('get_external_dependencies')) {
                my @ext_deps = @{ $node->get_external_dependencies() };
                if (@ext_deps == 0) {
                    # No external dependencies = structurally ready
                    if ($node->is_group) {
                        # Group nodes get copied to groups_ready for coordination
                        add_to_groups_ready($node, $groups_ready_nodes_ref);
                        log_debug("process_ready_pending_parent_buildnode: group " . $node->name . " is structurally ready, copied to groups_ready");
                    } else {
                        # Task nodes get copied to groups_ready for coordination
                        add_to_groups_ready($node, $groups_ready_nodes_ref);
                        log_debug("process_ready_pending_parent_buildnode: task " . $node->name . " is structurally ready, copied to groups_ready");
                    }
                } else {
                    log_debug("process_ready_pending_parent_buildnode: " . $node->name . " has " . scalar(@ext_deps) . " external dependencies, not structurally ready");
                }
            } else {
                # No external dependencies method = assume structurally ready
                if ($node->is_group) {
                    add_to_groups_ready($node, $groups_ready_nodes_ref);
                    log_debug("process_ready_pending_parent_buildnode: group " . $node->name . " (no ext deps method) copied to groups_ready");
                } else {
                    add_to_groups_ready($node, $groups_ready_nodes_ref);
                    log_debug("process_ready_pending_parent_buildnode: task " . $node->name . " (no ext deps method) copied to groups_ready");
                }
            }
        }
        
        # SECOND PASS: Move dependency-free tasks with ready parents to ready queue
        # Use array indices to avoid modification during iteration issues
        my $i = 0;
        log_debug("process_ready_pending_parent_buildnode: SECOND PASS - processing " . scalar(@$ready_pending_parent_nodes_ref) . " nodes");
        
        while ($i < @$ready_pending_parent_nodes_ref) {
            my $node = $ready_pending_parent_nodes_ref->[$i];
            
            log_debug("process_ready_pending_parent_buildnode: examining node " . ($node ? $node->name : 'undefined'));
            if ($node) {
                log_debug("process_ready_pending_parent_buildnode: " . $node->name . " - type: " . ($node->type // 'undefined') . ", is_group: " . ($node->is_group ? 'true' : 'false'));
            } else {
                log_debug("process_ready_pending_parent_buildnode: node is undefined, skipping");
                $i++;
                next;
            }
            
            # Skip if this node is not in groups_ready (not structurally ready)
	unless (is_node_in_groups_ready($node, $groups_ready_nodes_ref)) {
                log_debug("process_ready_pending_parent_buildnode: " . $node->name . " - not in groups_ready, skipping");
                $i++;
                next;
            }
            
            log_debug("process_ready_pending_parent_buildnode: " . $node->name . " - in groups_ready, checking dependencies");
            
            # Check if this node has no dependencies
            my @dependencies = @{ $node->dependencies || [] };
            log_debug("Node " . $node->name . " has " . scalar(@dependencies) . " dependencies");
            if (@dependencies == 0) {
                # No structural dependencies - check if it's conditional
                if ($node->conditional) {
                    # Conditional node - check if notification conditions are met
                    log_debug("Checking conditional node " . $node->name . " for readiness");
                    my $notifications_ok = check_notifications_succeeded_buildnode($node, $status_ref);
                    if ($notifications_ok) {
                        # All conditions met = ready for execution
                        add_to_ready_queue($node, $ready_queue_nodes_ref);
                        transition_node($node->key, 'pending', $registry, $status_ref);
                        log_debug("process_ready_pending_parent_buildnode: " . $node->name . " conditional conditions met, moved to ready");
                        
                        # Remove this node from ready_pending_parent using helper function
                        remove_from_ready_pending_parent($node, $ready_pending_parent_nodes_ref);
                        log_debug("process_ready_pending_parent_buildnode: removed " . $node->name . " from ready_pending_parent");
                        $moved_count++;
                        # Don't increment $i since we removed an element
                    } else {
                        # Conditions not met - stay in ready_pending_parent
                        log_debug("process_ready_pending_parent_buildnode: " . $node->name . " conditional conditions not met, staying in ready_pending_parent");
                        $i++;
                    }
                } else {
                    # Non-conditional node with no dependencies = ready for execution
                    add_to_ready_queue($node, $ready_queue_nodes_ref);
                    transition_node($node->key, 'pending', $registry, $status_ref);
                    log_debug("process_ready_pending_parent_buildnode: " . $node->name . " has no dependencies, moved to ready");
                    
                    # Remove this node from ready_pending_parent using helper function
                    remove_from_ready_pending_parent($node, $ready_pending_parent_nodes_ref);
                    log_debug("process_ready_pending_parent_buildnode: removed " . $node->name . " from ready_pending_parent");
                    $moved_count++;
                    # Don't increment $i since we removed an element
                }
            } else {
                # Has dependencies - check if all dependencies are satisfied
                my $all_deps_satisfied = 1;
                for my $dep (@dependencies) {
                    # Use graph_key for status lookup (same pattern as notifications and dependency resolution)
                    my $dep_key = $dep->key;
                    my $dep_status = $status_ref->{$dep_key};
                    if (!exists $status_ref->{$dep_key} || 
                        !is_successful_completion_status($dep_status)) {
                        $all_deps_satisfied = 0;
                        log_debug("process_ready_pending_parent_buildnode: " . $node->name . " dependency " . $dep->name . " not satisfied (status: " . ($dep_status // 'undefined') . ")");
                        last;
                    }
                }
                
                if ($all_deps_satisfied) {
                    # All structural dependencies satisfied - check if it's conditional
                    if ($node->conditional) {
                        # Conditional node - check if notification conditions are met
                        log_debug("Checking conditional node " . $node->name . " with dependencies for readiness");
                        my $notifications_ok = check_notifications_succeeded_buildnode($node, $status_ref);
                        if ($notifications_ok) {
                            # All conditions met = ready for execution
                            add_to_ready_queue($node, $ready_queue_nodes_ref);
                            transition_node($node->key, 'pending', $registry, $status_ref);
                            log_debug("process_ready_pending_parent_buildnode: " . $node->name . " conditional conditions met, moved to ready");
                            
                            # Remove this node from ready_pending_parent using helper function
                            remove_from_ready_pending_parent($node, $ready_pending_parent_nodes_ref);
                            log_debug("process_ready_pending_parent_buildnode: removed " . $node->name . " from ready_pending_parent");
                            $moved_count++;
                            # Don't increment $i since we removed an element
                        } else {
                            # Conditions not met - stay in ready_pending_parent
                            log_debug("process_ready_pending_parent_buildnode: " . $node->name . " conditional conditions not met, staying in ready_pending_parent");
                            $i++;
                        }
                    } else {
                        # Non-conditional node with satisfied dependencies = ready for execution
                        add_to_ready_queue($node, $ready_queue_nodes_ref);
                        transition_node($node->key, 'pending', $registry, $status_ref);
                        log_debug("process_ready_pending_parent_buildnode: " . $node->name . " all dependencies satisfied, moved to ready");
                        
                        # Remove this node from ready_pending_parent using helper function
                        remove_from_ready_pending_parent($node, $ready_pending_parent_nodes_ref);
                        log_debug("process_ready_pending_parent_buildnode: removed " . $node->name . " from ready_pending_parent");
                        $moved_count++;
                        # Don't increment $i since we removed an element
                    }
                } else {
                    log_debug("process_ready_pending_parent_buildnode: " . $node->name . " has unsatisfied dependencies, stays in ready_pending_parent");
                    $i++;
                }
            }
        }
        
        # No need to modify ready_pending_parent - nodes stay there until moved to ready
        # The COPY phase doesn't remove nodes, only the MOVE phase does
        # This preserves the queue structure naturally
        
        log_debug("process_ready_pending_parent_buildnode: moved $moved_count nodes, " . scalar(@$ready_pending_parent_nodes_ref) . " remaining");
        return $moved_count;
    }

# --- Helper Functions for Queue Management ---

# Check if a BuildNode is in the groups_ready queue
sub is_in_groups_ready {
	my ($node, $groups_ready_ref) = @_;
	return unless $node;
	return exists $groups_ready_ref->{$node};
}

# Remove a BuildNode from the ready_pending_parent queue
# remove_from_ready_pending_parent is now in BuildUtils.pm

# --- Three-Phase Execution Functions ---

# Phase 1: Coordination - Move nodes from RPP to GR based on coordination conditions
sub phase1_coordination {
    # Use global registry - no parameters needed
    
    log_debug("phase1_coordination: starting with " . scalar(@READY_PENDING_PARENT_NODES) . " nodes in RPP");
    
    my $nodes_copied = 0;
    
    # Debug: log the first few nodes to see what we're working with
    if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
        my $count = 0;
        for my $debug_node (get_eligible_pending_parent_nodes()) {
            $count++;
            if ($count <= 5) {  # Only log first 5 to avoid spam
                log_debug("phase1_coordination: node $count: " . (defined($debug_node) && $debug_node->can('name') ? $debug_node->name : 'unnamed'));
            }
        }
        log_debug("phase1_coordination: total nodes to process: " . scalar(get_eligible_pending_parent_nodes()));
    }
    
    # Check each node in ready_pending_parent to see if it can be moved to groups_ready
    # Use iterator function instead of direct access
    for my $node (get_eligible_pending_parent_nodes()) {
        # Debug: check if this is actually a BuildNode object
        unless (ref($node) && $node->isa('BuildNode')) {
            log_debug("phase1_coordination: WARNING - node is not a BuildNode: " . ref($node) . " - " . $node);
            next;
        }
        
        # Additional safety check before calling get_status
        if (!defined($node) || !ref($node) || !$node->can('name')) {
            log_debug("phase1_coordination: CRITICAL - node is invalid: " . (defined($node) ? ref($node) : 'undef') . " - " . $node);
            next;
        }
        
        # FAIL FAST: Skip if already in groups_ready
        if (is_node_in_groups_ready($node, \%GROUPS_READY_NODES)) {
            if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
                log_debug("phase1_coordination: skipping " . $node->name . " - already in groups_ready");
            }
            next;
        }
        
        my $node_key = $node->key;
        my $current_status = $STATUS_MANAGER->get_status($node);
        
        # Skip nodes that are not in pending status
        next unless $current_status eq 'pending';
        
        # Check if all external dependencies are satisfied (Phase 1 only checks external deps)
        my $dependencies_satisfied = 1;
        my $deps = $node->get_external_dependencies;
        for my $dep_node (@$deps) {
            # Debug: log what we're about to pass to get_status for dependencies
            if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
                log_debug("phase1_coordination: Checking external dependency: " . (defined($dep_node) && $dep_node->can('name') ? $dep_node->name : 'unnamed'));
            }
            
            my $dep_status = $STATUS_MANAGER->get_status($dep_node);
            if ($dep_status ne 'done' && $dep_status ne 'skipped') {
                $dependencies_satisfied = 0;
                if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
                    log_debug("phase1_coordination: External dependency " . $dep_node->name . " not satisfied (status: $dep_status)");
                }
                last;
            }
        }
        
        # Check if this node can coordinate its children (should coordinate next)
        # Root nodes (no parents) should always be able to coordinate
        my $can_coordinate = $node->should_coordinate_next(\%GROUPS_READY_NODES);
        
        if ($BuildUtils::VERBOSITY_LEVEL >= 2) {
            if (!$dependencies_satisfied) {
                log_debug("phase1_coordination: node " . $node->name . " dependencies not satisfied");
            }
            if (!$can_coordinate) {
                log_debug("phase1_coordination: node " . $node->name . " cannot coordinate");
            }
        }
        
        # If dependencies are satisfied AND node can coordinate, copy to groups_ready
        if ($dependencies_satisfied && $can_coordinate) {
            add_to_groups_ready($node);
            $nodes_copied++;
            log_debug("phase1_coordination: copied node " . $node->name . " to groups_ready");
            
            # OPTIMIZATION: If node has an auto-generated dependency group, automatically copy it to GR
            if ($node->can('children') && $node->children && ref($node->children) eq 'ARRAY') {
                for my $child (@{$node->children}) {
                    if (($child->get_child_order // 0) == 0) {  # dependency group (child_id 0)
                        my $dep_group_status = $STATUS_MANAGER->get_status($child);
                        if ($dep_group_status eq 'pending') {
                            add_to_groups_ready($child);
                            $nodes_copied++;
                            log_debug("phase1_coordination: OPTIMIZATION: auto-copied dependency group " . $child->name . " to groups_ready");
                        }
                    }
                }
            }
        }
    }
    
    log_debug("phase1_coordination: copied $nodes_copied nodes from RPP to groups_ready");
    return $nodes_copied;
}

# Phase 2: Execution Preparation - Move nodes from RPP to Ready queue when ready for execution
sub phase2_execution_preparation {
    # Use global registry - no parameters needed
    
    log_debug("phase2_execution_preparation: starting with " . scalar(@READY_PENDING_PARENT_NODES) . " nodes in RPP and " . scalar(keys %GROUPS_READY_NODES) . " nodes in GR");
    
    my $nodes_moved = 0;
    
    # Check each node in RPP to see if it can be moved to ready queue
    # Condition: node must be in GR AND ready for execution
    for my $node (get_eligible_pending_parent_nodes()) {
        
        # Debug: check if this is actually a BuildNode object by checking for required methods
        unless (ref($node) && $node->can('name') && $node->can('key')) {
            log_debug("phase2_execution_preparation: WARNING - node is not a BuildNode: " . ref($node) . " - " . (defined($node) && $node->can('name') ? $node->name : 'unnamed'));
            next;
        }
        
 #       my $node_key = $node->key;
        
        # Skip nodes that are not in pending status
        # Probably unnecessary.
        unless ($STATUS_MANAGER->is_pending($node)) {
            if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
                my $status = $STATUS_MANAGER->get_status($node);
                log_debug("phase2_execution_preparation: node " . $node->name . " not pending (status: $status), skipping");
            }
            next;
        }
        
        # Check if this node is in groups_ready
        unless (is_node_in_groups_ready($node)) {
            log_debug("phase2_execution_preparation: node " . $node->name . " not in groups_ready, skipping");
            next;
        }
        
        # Debug: log what we're checking
        if ($VERBOSITY_LEVEL >= 3) {
            my $child_order = $node->can('get_child_order') ? $node->get_child_order : 'UNKNOWN';
            my $has_parents = $node->has_any_parents() ? 'YES' : 'NO';
            log_debug("phase2_execution_preparation: checking node " . $node->name . " (child_order: $child_order, has_parents: $has_parents)");
        }
        
        # Additional debug for conditional nodes
        if ($node->conditional) {
            my $has_parents = $node->has_any_parents() ? 'YES' : 'NO';
            log_debug("phase2_execution_preparation: Conditional node " . $node->name . " has_parents: $has_parents");
            if ($node->has_any_parents()) {
                my $parents = $node->get_parents;
                log_debug("phase2_execution_preparation: Conditional node " . $node->name . " has " . scalar(@$parents) . " parents");
                for my $parent (@$parents) {
                    log_debug("phase2_execution_preparation:   Parent: " . $parent->name);
                }
            }
        }
        
        # Start pessimistic - node is not ready by default
        my $ready_for_execution = 0;
        
        # Check if node has any parents
        if ($node->has_any_parents()) {
            my $parents = $node->get_parents;
            
            # Debug: log parent checking
            if ($VERBOSITY_LEVEL >= 3) {
                log_debug("phase2_execution_preparation: node " . $node->name . " has parents, checking coordination readiness");
            }
            
            # Check each parent for coordination readiness
            for my $parent (@$parents) {
                # Parent must be in groups_ready
                next unless is_node_in_groups_ready($parent);
                
                        # Check if parent's dependency group (child_id 0) is complete
        my $dependency_group_complete = 1;
        if ($parent->can('children') && $parent->children && ref($parent->children) eq 'ARRAY') {
            for my $child (@{$parent->children}) {
                if (($child->get_child_order // 999) == 0) {  # dependency group (child_id 0)
                    my $dep_group_status = $STATUS_MANAGER->get_status($child);
                    if ($VERBOSITY_LEVEL >= 3) {
                        log_debug("phase2_execution_preparation: checking parent " . $parent->name . " dependency group " . $child->name . " status: " . $dep_group_status);
                    }
                    if (!is_successful_completion_status($dep_group_status)) {
                        $dependency_group_complete = 0;
                        last;
                    }
                }
            }
        }
                
                # Single check: child_id == 0 || child_id 0 complete
                if (($node->get_child_order // 999) == 0 || $dependency_group_complete) {
                    $ready_for_execution = 1;
                                         if ($VERBOSITY_LEVEL >= 3) {
                         if (($node->get_child_order // 999) == 0) {
                             log_debug("phase2_execution_preparation: node " . $node->name . " is a dependency group (child_id 0), can execute immediately");
                         } else {
                             log_debug("phase2_execution_preparation: node " . $node->name . " is ready for execution (parent " . $parent->name . " dependency group complete)");
                         }
                     }
                    last;  # Found one ready parent
                }
            }
        } else {
            # No parents = root node, always ready TO COORDINATE
            if ($VERBOSITY_LEVEL >= 3) {
                log_debug("phase2_execution_preparation: node " . $node->name . " has no parents (root node), always ready to coordinate");
            }
            $ready_for_execution = 1;
        }
        
        # UNIVERSAL CHECK: If this node has children, they must all be complete before it can execute
        # This applies to ALL nodes (with or without parents) that have children
        if ($ready_for_execution && $node->children && ref($node->children) eq 'ARRAY' && @{$node->children}) {
            my $all_children_complete = 1;
            for my $child (@{$node->children}) {
                my $child_status = $STATUS_MANAGER->get_status($child);
                if (!is_successful_completion_status($child_status)) {
                    $all_children_complete = 0;
                    if ($VERBOSITY_LEVEL >= 3) {
                        log_debug("phase2_execution_preparation: node " . $node->name . " cannot execute - child " . $child->name . " not complete (status: " . ($child_status // 'undefined') . ")");
                    }
                    last;
                }
            }
            if (!$all_children_complete) {
                $ready_for_execution = 0;
                if ($VERBOSITY_LEVEL >= 3) {
                    log_debug("phase2_execution_preparation: node " . $node->name . " not ready - waiting for all children to complete");
                }
            }
        }
        
        # Additional check for conditional nodes - this overrides the parent/children logic
        if ($node->conditional) {
            # Conditional node - check if notification conditions are met
            log_debug("phase2_execution_preparation: Checking conditional node " . $node->name . " for readiness");
            my $notifications_ok = check_notifications_succeeded_buildnode($node, $STATUS_MANAGER->{status});
            if (!$notifications_ok) {
                $ready_for_execution = 0;
                log_debug("phase2_execution_preparation: Conditional node " . $node->name . " conditions not met, staying in RPP");
            } else {
                $ready_for_execution = 1;
                log_debug("phase2_execution_preparation: Conditional node " . $node->name . " conditions met, ready for execution");
            }
        }
        
        # Move from RPP to Ready if conditions are met
        if ($ready_for_execution) {
            add_to_ready_queue($node);
            remove_from_ready_pending_parent($node);  # Remove from RPP
            
            # Set node status to 'ready' - this will automatically add breadcrumb and track execution order
            $STATUS_MANAGER->set_status($node, 'ready');
            
            $nodes_moved++;
            log_debug("phase2_execution_preparation: moved node " . $node->name . " from RPP to ready queue");
        }
    }
    
    log_debug("phase2_execution_preparation: moved $nodes_moved nodes from RPP to ready queue");
    return $nodes_moved;
}

# Phase 3: Actual Execution - Execute nodes from Ready queue and process notifications
sub phase3_actual_execution {
    my ($is_validate, $is_dry_run) = @_;
    # Use global registry - no parameters needed
    
    log_debug("phase3_actual_execution: starting with " . scalar(@READY_QUEUE_NODES) . " nodes in ready queue");
    
    my $nodes_executed = 0;
    
    # Execute all nodes in the ready queue
    while (my $node = get_next_ready_node()) {
        # Get next eligible node without removing it from queue
        
        my $node_key = $node->key;
        
        # Check if node is already completed - this should not happen!
        my $current_status = $STATUS_MANAGER->get_status($node);
        if (BuildStatusManager::is_successful_status($current_status)) {
            log_error("phase3_actual_execution: FATAL ERROR - already completed node " . $node->name . " (status: $current_status) found in ready queue!");
            log_error("This indicates a serious queue management bug. Terminating build to prevent data corruption.");
            
            # DEBUG: Output queue sizes and node details to diagnose the issue
            log_error("DEBUG INFO - Queue sizes when error occurred:");
            log_error("  Ready queue size: " . scalar(@READY_QUEUE_NODES));
            log_error("  Groups ready size: " . scalar(keys %GROUPS_READY_NODES));
            log_error("  RPP size: " . scalar(@READY_PENDING_PARENT_NODES));
            my $build_summary = $STATUS_MANAGER->get_build_summary();
            log_error("  Total execution order: " . $build_summary->{nodes_in_execution_order});
            log_error("  Node key: " . $node->key);
            log_error("  Node name: " . $node->name);
            log_error("  Node status: " . $current_status);
            
            # Check if this node appears multiple times in the ready queue
            my $node_count = grep { $_->key eq $node->key } @READY_QUEUE_NODES;
            log_error("  This node appears $node_count times in ready queue");
            
            die "Queue management bug detected - completed node found in ready queue\n";
        }
        
        log_debug("phase3_actual_execution: executing node " . $node->name);
        
        # Execute the node based on mode
        my $new_status;
        if ($is_validate) {
            # Log validate mode to command log
            my $command_log_file = "$BUILD_SESSION_DIR/COMMAND_EXECUTION.log";
            my $timestamp = localtime();
            my $node_name = $node->name;
            open(my $cmd_log, '>>', $command_log_file) or log_error("Cannot open command log: $!");
            print $cmd_log "[$timestamp] EXECUTING: $node_name\n";
            print $cmd_log "[$timestamp] COMMAND: (VALIDATE - would execute)\n";
            print $cmd_log "[$timestamp] RESULT: SUCCESS (validate mode)\n";
            print $cmd_log "-" x 80 . "\n";
            close($cmd_log);
            
            $new_status = 'validate';
            log_debug("VALIDATE: Would execute " . $node_name);
        } elsif ($is_dry_run) {
            # Log dry-run mode to command log
            my $command_log_file = "$BUILD_SESSION_DIR/COMMAND_EXECUTION.log";
            my $timestamp = localtime();
            my $node_name = $node->name;
            open(my $cmd_log, '>>', $command_log_file) or log_error("Cannot open command log: $!");
            print $cmd_log "[$timestamp] EXECUTING: $node_name\n";
            print $cmd_log "[$timestamp] COMMAND: (DRY-RUN - would execute)\n";
            print $cmd_log "[$timestamp] RESULT: SUCCESS (dry-run mode)\n";
            print $cmd_log "-" x 80 . "\n";
            close($cmd_log);
            
            $new_status = 'dry-run';
            log_debug("DRY-RUN: Would execute " . $node_name);
        } else {
            # Real execution - actually execute the node
            my $command = $node->command // $node->build_command;
            if ($command) {
                # Get node args and expand command
                my $node_args = $node->get_args || {};
                my $expanded_cmd = expand_command_args($command, $node_args);
                
                log_info("Executing: " . $node->name);
                log_debug("Executing node " . $node->name . " with expanded command: $expanded_cmd");
                
                # Always log command output to files, then show in terminal based on verbosity
                my $result;
                my $log_file = "$BUILD_SESSION_DIR/" . sanitize_log_name($node->name) . ".log";
                
                # Log every command execution to a comprehensive command log
                my $command_log_file = "$BUILD_SESSION_DIR/COMMAND_EXECUTION.log";
                my $timestamp = localtime();
                my $node_name = $node->name;
                open(my $cmd_log, '>>', $command_log_file) or log_error("Cannot open command log: $!");
                print $cmd_log "[$timestamp] EXECUTING: $node_name\n";
                print $cmd_log "[$timestamp] COMMAND: $expanded_cmd\n";
                print $cmd_log "[$timestamp] LOG_FILE: $log_file\n";
                print $cmd_log "-" x 80 . "\n";
                close($cmd_log);
                
                if ($VERBOSITY_LEVEL == 0) {
                    # Quiet mode: redirect all output to log files only
                    $result = system("$expanded_cmd > $log_file 2>&1");
                } else {
                    # Normal/verbose/debug mode: log to file AND show in terminal
                    # Use bash to properly handle PIPESTATUS for exit code preservation
                    $result = system("bash -c '($expanded_cmd) 2>&1 | tee $log_file; exit \${PIPESTATUS[0]}'");
                }
                # Log command result to command log
                open(my $result_log, '>>', $command_log_file) or log_error("Cannot open command log: $!");
                if ($result == 0) {
                    print $result_log "[$timestamp] RESULT: SUCCESS (exit code: 0)\n";
                    close($result_log);
                    $new_status = 'done';
                    log_info("Completed: " . $node->name);
                    log_debug("Node " . $node->name . " completed successfully");
                } else {
                    print $result_log "[$timestamp] RESULT: FAILED (exit code: " . ($result >> 8) . ")\n";
                    close($result_log);
                    $new_status = 'failed';
                    log_error("Node " . $node->name . " failed with exit code: " . ($result >> 8));
                    # Remove failed node from groups_ready queue
                    remove_from_groups_ready($node);
                }
            } else {
                # No command to execute, mark as done
                # Log this to command log as well
                my $command_log_file = "$BUILD_SESSION_DIR/COMMAND_EXECUTION.log";
                my $timestamp = localtime();
                my $node_name = $node->name;
                open(my $cmd_log, '>>', $command_log_file) or log_error("Cannot open command log: $!");
                print $cmd_log "[$timestamp] EXECUTING: $node_name\n";
                print $cmd_log "[$timestamp] COMMAND: (NO COMMAND - marking as done)\n";
                print $cmd_log "[$timestamp] RESULT: SUCCESS (no command to execute)\n";
                print $cmd_log "-" x 80 . "\n";
                close($cmd_log);
                
                $new_status = 'done';
                log_debug("Node " . $node_name . " has no command, marking as done");
            }
        }
        
        # Update status using transition function to handle notifications
        if ($VERBOSITY_LEVEL >= 3) {
            log_debug("phase3_actual_execution: setting node " . $node->name . " status to: " . $new_status);
        }
        transition_node_buildnode($node, $new_status, $STATUS_MANAGER->{status}, $REGISTRY);
        
        # Execution order is now tracked in Phase 2 when nodes become ready
        
        # Process notifications to dependent nodes - direct access, no registry scan needed
        if ($node->can('get_notifies')) {
            my @unconditional = @{ $node->get_notifies() || [] };
            if (@unconditional) {
                log_debug("Processing unconditional notifications from " . $node->name . " to " . 
                         join(", ", map { $_->name } @unconditional));
            }
        }
        
        if ($node->can('get_notifies_on_success')) {
            my @success = @{ $node->get_notifies_on_success() || [] };
            if (@success) {
                log_debug("Processing success notifications from " . $node->name . " to " . 
                         join(", ", map { $_->name } @success));
            }
        }
        
        if ($node->can('get_notifies_on_failure')) {
            my @failure = @{ $node->get_notifies_on_failure() || [] };
            if (@failure) {
                log_debug("Processing failure notifications from " . $node->name . " to " . 
                         join(", ", map { $_->name } @failure));
            }
        }
        
        # Remove the completed node from ready queue using helper function
        remove_from_ready_queue($node);
        
        $nodes_executed++;
    }
    
    log_debug("phase3_actual_execution: executed $nodes_executed nodes");
    return $nodes_executed;
}

# --- Build Node Execution Engine (DRY: handles both execution and validation) ---
sub execute_build_nodes {
    # Optional parameter: target name (root node name)
    my $target_name = shift;
    
    # Use global execution mode flags
    my $is_dry_run = $IS_DRY_RUN;
    my $is_validate = $IS_VALIDATE;
    
    # CRITICAL: Process notification relationships to populate BuildNode objects
    # This ensures both sides of notification relationships are established
    log_debug("execute_build_nodes: processing notification relationships");
    $REGISTRY->_process_notifications();
    log_debug("execute_build_nodes: notification relationships processed");
    
    # Get all nodes directly from the registry
    my $all_nodes = $REGISTRY->all_nodes;
    my @all_nodes_objects = grep { ref($_) && $_->isa('BuildNode') } values %$all_nodes;
    
    # Debug: log any non-BuildNode objects that were filtered out
    if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
        my @all_values = values %$all_nodes;
        my $filtered_count = @all_values - @all_nodes_objects;
        if ($filtered_count > 0) {
            log_debug("execute_build_nodes: filtered out $filtered_count non-BuildNode objects from registry");
        }
    }
    # Clear breadcrumbs and reset execution order tracking
    $STATUS_MANAGER->clear_breadcrumbs();
    
    # BuildNode-based three-queue system - now using global queues
    # @READY_PENDING_PARENT_NODES, @READY_QUEUE_NODES, %GROUPS_READY_NODES
    
    # Initialize all nodes to pending status and add to ready_pending_parent
    for my $node (@all_nodes_objects) {
        $STATUS_MANAGER->set_status($node, 'pending');
        push @READY_PENDING_PARENT_NODES, $node;
        
    }
    
    # CRITICAL: Add root node (target) to groups_ready before loop starts
    # This unblocks the entire dependency graph from the start
    if ($target_name) {
        my $root_node = $REGISTRY->get_node_by_name_and_args($target_name, {});
        if ($root_node) {
            if ($BuildUtils::VERBOSITY_LEVEL >= 2) {
                log_debug("execute_build_nodes: Found target root node: " . $root_node->name);
            }
            
            # Check if root node's external dependencies are satisfied
            my $dependencies_satisfied = 1;
            my $deps = $root_node->get_external_dependencies;
            for my $dep_node (@$deps) {
                my $dep_status = $STATUS_MANAGER->get_status($dep_node);
                if ($dep_status ne 'done' && $dep_status ne 'skipped') {
                    $dependencies_satisfied = 0;
                    if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
                        log_debug("execute_build_nodes: Root node external dependency " . $dep_node->name . " not satisfied (status: $dep_status)");
                    }
                    last;
                }
            }
            
            # Root node can always coordinate (no parent check needed)
            if ($dependencies_satisfied) {
                add_to_groups_ready($root_node);
                if ($BuildUtils::VERBOSITY_LEVEL >= 2) {
                    log_debug("execute_build_nodes: Added root node " . $root_node->name . " to groups_ready");
                }
                
                # Also add root node's dependency group if it exists
                if ($root_node->can('children') && $root_node->children && ref($root_node->children) eq 'ARRAY') {
                    for my $child (@{$root_node->children}) {
                        if (($child->get_child_order // 0) == 0) {  # dependency group (child_id 0)
                            my $dep_group_status = $STATUS_MANAGER->get_status($child);
                            if ($dep_group_status eq 'pending') {
                                add_to_groups_ready($child);
                                if ($BuildUtils::VERBOSITY_LEVEL >= 2) {
                                    log_debug("execute_build_nodes: Added root node's dependency group " . $child->name . " to groups_ready");
                                }
                            }
                        }
                    }
                }
            } else {
                if ($BuildUtils::VERBOSITY_LEVEL >= 2) {
                    log_debug("execute_build_nodes: Root node " . $root_node->name . " has unsatisfied external dependencies, will be processed in phase1");
                }
            }
        } else {
            log_warn("execute_build_nodes: Target root node '$target_name' not found in registry");
        }
    }
    
    # Main execution loop using three-phase approach
    my $iterations = 0;
    my $max_iterations = scalar(@all_nodes_objects) * 2; # Prevent infinite loops
    my $no_progress_count = 0;
    
    log_debug("=== ENTERING MAIN EXECUTION LOOP ===");
    log_debug("Starting main execution loop with " . scalar(@all_nodes_objects) . " total nodes");
    log_debug("Initial queue states:");
    log_debug("  RPP: " . get_ready_pending_parent_size() . " nodes");
    log_debug("  Ready: " . get_ready_queue_size() . " nodes"); 
    log_debug("  GR: " . get_groups_ready_size() . " nodes");
    
    while (get_ready_queue_size() > 0 || get_ready_pending_parent_size() > 0) {
        $iterations++;
        last if $iterations > $max_iterations;
        
        log_debug("=== ITERATION $iterations ===");
        log_debug("Queue sizes: rpp=" . get_ready_pending_parent_size() . ", ready=" . get_ready_queue_size() . ", gr=" . get_groups_ready_size());
        
        # Phase 1: Coordination - Move nodes from RPP to GR based on coordination conditions
        log_debug("=== STARTING PHASE 1 ===");
        my $nodes_copied_to_gr = phase1_coordination();
        log_debug("Phase 1 result: copied $nodes_copied_to_gr nodes to GR");
        
        # Phase 2: Execution Preparation - Move nodes from RPP to Ready queue when ready for execution
        log_debug("=== STARTING PHASE 2 ===");
        my $nodes_moved_to_ready = phase2_execution_preparation();
        log_debug("Phase 2 result: moved $nodes_moved_to_ready nodes to Ready");
        
        # Phase 3: Actual Execution - Execute nodes from Ready queue and process notifications
        log_debug("=== STARTING PHASE 3 ===");
        my $nodes_executed = phase3_actual_execution($is_validate, $is_dry_run);
        log_debug("Phase 3 result: executed $nodes_executed nodes");
        
        # Debug: Show detailed queue states after each phase
        log_debug("=== AFTER ALL PHASES ===");
        log_debug("Queue states after iteration $iterations:");
        log_debug("  RPP size: " . get_ready_pending_parent_size());
        log_debug("  Ready size: " . get_ready_queue_size());
        log_debug("  GR size: " . get_groups_ready_size());
        
        # Show what's in each queue
        if (get_ready_pending_parent_size() > 0) {
            log_debug("  RPP nodes remaining:");
            for my $i (0 .. min(4, get_ready_pending_parent_size() - 1)) {
                my $node = $READY_PENDING_PARENT_NODES[$i];
                my $status = $STATUS_MANAGER->get_status($node);
                my $in_gr = is_node_in_groups_ready($node) ? "YES" : "NO";
                log_debug("    " . $node->name . " (status: $status, in GR: $in_gr)");
            }
        }
        
        if (get_ready_queue_size() > 0) {
            log_debug("  Ready queue nodes:");
            for my $i (0 .. min(4, get_ready_queue_size() - 1)) {
                my $node = $READY_QUEUE_NODES[$i];
                my $status = $STATUS_MANAGER->get_status($node);
                log_debug("    " . $node->name . " (status: $status)");
            }
        }
        
        # Check loop condition
        log_debug("Loop condition check:");
        log_debug("  Ready queue size > 0: " . (get_ready_queue_size() > 0 ? "YES" : "NO"));
        log_debug("  RPP size > 0: " . (get_ready_pending_parent_size() > 0 ? "YES" : "NO"));
        log_debug("  Loop should continue: " . ((get_ready_queue_size() > 0 || get_ready_pending_parent_size() > 0) ? "YES" : "NO"));
        
        if ($BuildUtils::VERBOSITY_LEVEL >= 2) {
            log_debug("DEBUG: Queue states after iteration $iterations:");
            log_debug("  RPP size: " . get_ready_pending_parent_size());
            log_debug("  Ready size: " . get_ready_queue_size());
            log_debug("  GR size: " . get_groups_ready_size());
            
            # Show what's in each queue
            if (get_ready_pending_parent_size() > 0) {
                log_debug("  RPP nodes remaining:");
                for my $i (0 .. min(4, get_ready_pending_parent_size() - 1)) {
                    my $node = $READY_PENDING_PARENT_NODES[$i];
                    my $status = $STATUS_MANAGER->get_status($node);
                    my $in_gr = is_node_in_groups_ready($node) ? "YES" : "NO";
                    log_debug("    " . $node->name . " (status: $status, in GR: $in_gr)");
                }
            }
            
            if (get_ready_queue_size() > 0) {
                log_debug("  Ready queue nodes:");
                for my $i (0 .. min(4, get_ready_queue_size() - 1)) {
                    my $node = $READY_QUEUE_NODES[$i];
                    my $status = $STATUS_MANAGER->get_status($node);
                    log_debug("    " . $node->name . " (status: $status)");
                }
            }
        }
        
        # Check for no progress
        if ($nodes_copied_to_gr == 0 && $nodes_moved_to_ready == 0 && $nodes_executed == 0) {
            $no_progress_count++;
            log_debug("No progress detected in iteration $iterations (consecutive: $no_progress_count)");
            
            # Add detailed debugging for why no progress is happening
            if ($BuildUtils::VERBOSITY_LEVEL >= 2) {
                log_debug("DEBUG: Queue states when no progress:");
                log_debug("  RPP size: " . get_ready_pending_parent_size());
                log_debug("  Ready size: " . get_ready_queue_size());
                log_debug("  GR size: " . get_groups_ready_size());
                
                # Show all RPP nodes to understand what's blocking
                if (get_ready_pending_parent_size() > 0) {
                    log_debug("  All RPP nodes remaining:");
                    for my $i (0 .. get_ready_pending_parent_size() - 1) {
                        my $node = $READY_PENDING_PARENT_NODES[$i];
                        my $status = $STATUS_MANAGER->get_status($node);
                        my $in_gr = is_node_in_groups_ready($node) ? "YES" : "NO";
                        log_debug("    " . $node->name . " (status: $status, in GR: $in_gr)");
                        
                        # If node is in GR but not ready, check why
                        if ($in_gr eq "YES" && $status eq "pending") {
                            log_debug("      Node is in GR but still pending - checking parent coordination");
                            if ($node->has_any_parents()) {
                                my $parents = $node->get_parents;
                                for my $parent (@$parents) {
                                    my $parent_in_gr = is_node_in_groups_ready($parent) ? "YES" : "NO";
                                    my $parent_status = $STATUS_MANAGER->get_status($parent);
                                    log_debug("        Parent " . $parent->name . " (in GR: $parent_in_gr, status: $parent_status)");
                                    
                                    # Check dependency group status
                                    if ($parent->can('children') && $parent->children && ref($parent->children) eq 'ARRAY') {
                                        for my $child (@{$parent->children}) {
                                            if (($child->get_child_order // 0) == 0) {  # dependency group (child_id 0)
                                                my $dep_group_status = $STATUS_MANAGER->get_status($child);
                                                log_debug("          Dependency group " . $child->name . " status: $dep_group_status");
                                            }
                                        }
                                    }
                                }
                            } else {
                                log_debug("      Node has no parents - should be ready");
                            }
                        }
                    }
                }
            }
            
            if ($no_progress_count >= 3) {
                log_debug("Breaking loop due to no progress for $no_progress_count consecutive iterations");
                last;
            }
        } else {
            # Reset no progress counter if we made progress
            $no_progress_count = 0;
        }
        
        # Log progress summary
        log_debug("Iteration $iterations progress: copied_to_gr=$nodes_copied_to_gr, moved_to_ready=$nodes_moved_to_ready, executed=$nodes_executed");
        
        # Debug: Show execution order after each iteration
        if ($BuildUtils::VERBOSITY_LEVEL >= 2) {
            my $build_summary = $STATUS_MANAGER->get_build_summary();
            log_debug("Iteration $iterations execution order size: " . $build_summary->{nodes_in_execution_order});
            if ($build_summary->{nodes_in_execution_order} > 0) {
                my @order_names = $STATUS_MANAGER->get_execution_order_names();
                log_debug("Current execution order: " . join(", ", @order_names));
            }
        }
    }
    
    # Debug: Show loop termination details
    log_debug("=== LOOP TERMINATED ===");
    log_debug("Final queue states:");
    log_debug("  RPP: " . get_ready_pending_parent_size() . " nodes");
    log_debug("  Ready: " . get_ready_queue_size() . " nodes");
    log_debug("  GR: " . get_groups_ready_size() . " nodes");
    log_debug("Total iterations: $iterations");
    
    # Final check for stalled nodes in RPP
    if (@READY_PENDING_PARENT_NODES > 0) {
        log_debug("Final RPP nodes remaining: " . scalar(@READY_PENDING_PARENT_NODES));
        for my $node (@READY_PENDING_PARENT_NODES) {
            log_debug("  Remaining in RPP: " . $node->name . " (status: " . $STATUS_MANAGER->get_status($node) . ")");
        }
    }
    
    # Log final execution order details from status manager
    my $build_summary = $STATUS_MANAGER->get_build_summary();
    log_debug("Status Manager execution order size: " . $build_summary->{nodes_in_execution_order});
    log_debug("Status Manager total nodes: " . $build_summary->{total_nodes});
    log_debug("Nodes in execution order vs total: " . $build_summary->{nodes_in_execution_order} . "/" . $build_summary->{total_nodes});
    
    # Check if any nodes failed
    my $failed_count = $build_summary->{failed_nodes} || 0;
    my $success = ($failed_count == 0) ? 1 : 0;
    
    
    # Return execution results - status manager is now global
    return ($success, $build_summary->{execution_order}, {}, \%GROUPS_READY_NODES);
}

# --- Helper function to build tree for a group ---
# WHAT: Builds a tree for a specific build group using the standard pattern
# HOW: Creates registry, extracts globals, builds graph, and registers the tree
# WHY: Eliminates duplicate tree building code across multiple execution modes
# PUBLIC: This function can be called independently for tree building
sub build_tree_for_group {
    my ($group, $cfg, $global_defaults) = @_;
    
    my $registry = BuildNodeRegistry->new;
    my $tree = build_graph_with_worklist($group, {}, $cfg, $global_defaults, $registry);
    $registry->build_from_tree($tree);
    
    return ($registry, $tree);
}

sub print_build_summary {
    my ($execution_order_ref, $duration_ref) = @_;
    # Use global registry - no parameters needed
    
    print "\n" . "=" x 60 . "\n";
    print "BUILD SUMMARY\n";
    print "=" x 60 . "\n";
    
    my $total_nodes = 0;
    my $successful_nodes = 0;
    my $failed_nodes = 0;
    my $skipped_nodes = 0;
    my $dry_run_nodes = 0;
    my $validate_nodes = 0;
    
    # Count nodes by status using the global status manager API
    my $all_statuses = $STATUS_MANAGER->get_all_statuses();
    for my $status (values %$all_statuses) {
        $total_nodes++;
        if ($status eq 'done') {
            $successful_nodes++;
        } elsif ($status eq 'failed') {
            $failed_nodes++;
        } elsif ($status eq 'skipped') {
            $skipped_nodes++;
        } elsif ($status eq 'dry-run') {
            $dry_run_nodes++;
        } elsif ($status eq 'validate') {
            $validate_nodes++;
        }
    }
    
    print "Total nodes processed: $total_nodes\n";
    print "Successful: $successful_nodes\n";
    print "Failed: $failed_nodes\n";
    print "Skipped: $skipped_nodes\n";
    if ($dry_run_nodes > 0) {
        print "Dry-run: $dry_run_nodes\n";
    }
    if ($validate_nodes > 0) {
        print "Validate: $validate_nodes\n";
    }
    
    if ($failed_nodes > 0) {
        print "\n❌ BUILD FAILED\n";
    } else {
        print "\n✅ BUILD SUCCEEDED\n";
    }
    
    print "=" x 60 . "\n";
    
    # If in validate mode, show additional details
    if ($IS_VALIDATE) {
        print "\n" . "-" x 60 . "\n";
        print "VALIDATION DETAILS\n";
        print "-" x 60 . "\n";
        
        # Show tree order
        print "\nTREE ORDER:\n";
        # Get the root node from the registry (assuming it's the first node or we can find it)
        my $all_nodes = $REGISTRY->all_nodes;
        

        
        my @root_nodes = grep { !$_->has_any_parents } values %$all_nodes;
        
        if (@root_nodes) {
            # Find the first group node, or use the first node if no groups
            my @group_roots = grep { $_->is_group } @root_nodes;
            my $root_node = $group_roots[0] || $root_nodes[0];
            
            if ($VERBOSITY_LEVEL >= 3) {
                log_debug("Root nodes found: " . scalar(@root_nodes));
                for my $root (@root_nodes) {
                    log_debug("  Root: " . $root->name);
                }
                log_debug("Selected root node: " . $root_node->name);
            }
            print_enhanced_tree($root_node, $REGISTRY, { show_notifications => 1 });
        } else {
            print "  No root nodes found\n";
        }
        
        # Show notification order - COMMENTED OUT FOR NOW (needs rework)
        # print "\nNOTIFICATION ORDER:\n";
        # my @notifications = enumerate_notifications($REGISTRY);
        # if (@notifications) {
        #     for my $notification (@notifications) {
        #         my ($node, $unconditional, $success, $failure) = @$notification;
        #         print "  " . $node->name . ":\n";
        #         if ($unconditional && @$unconditional) {
        #             print "    Unconditional: " . join(", ", map { $_->name } @$unconditional) . "\n";
        #         }
        #         if ($success && @$success) {
        #             print "    On Success: " . join(", ", map { $_->name } @$success) . "\n";
        #         }
        #         if ($failure && @$failure) {
        #             print "    On Failure: " . join(", ", map { $_->name } @$failure) . "\n";
        #         }
        #     }
        # } else {
        #     print "  No notifications defined\n";
        # }
        
        print "-" x 60 . "\n";
    }
    
    # Show execution order for single-target modes (not bulk validation) - final section
    # Show execution order for: display mode, dry-run, explicit target, or default target (not in validation mode)
    if ($display || $dry_run || $target || (!$target && !$IS_VALIDATE)) {
        print "\n" . "-" x 60 . "\n";
        print "EXECUTION ORDER\n";
        print "-" x 60 . "\n";
        
        # Show actual execution order for all modes
        if ($execution_order_ref && @$execution_order_ref > 0) {
            # Filter out empty dependency groups and track display index separately
            my $display_index = 0;
            for my $i (0 .. $#$execution_order_ref) {
                my $execution_entry = $execution_order_ref->[$i];
                # Execution order now contains hashes with node information
                if (ref($execution_entry) eq 'HASH' && exists $execution_entry->{node_name}) {
                    # Skip empty dependency groups
                    if (exists $execution_entry->{node_key} && $REGISTRY) {
                        my $node = $REGISTRY->get_node_by_key($execution_entry->{node_key});
                        if ($node && is_empty_dependency_group($node)) {
                            next; # Skip this entry
                        }
                    }
                    
                    $display_index++;
                    my $display_status = $execution_entry->{status};
                    my $display_timestamp = $execution_entry->{timestamp};
                    
                    # Use completion timestamp if available, otherwise use ready timestamp
                    if (exists $execution_entry->{completion_timestamp}) {
                        $display_timestamp = $execution_entry->{completion_timestamp};
                    }
                    
                    # Format status for better readability
                    if ($display_status eq 'done') {
                        $display_status = 'completed';
                    } elsif ($display_status eq 'failed') {
                        $display_status = 'failed';
                    } elsif ($display_status eq 'skipped') {
                        $display_status = 'skipped';
                    } elsif ($display_status eq 'not-run') {
                        $display_status = 'not-run';
                    } elsif ($display_status eq 'ready') {
                        $display_status = 'ready';
                    } elsif ($display_status eq 'executing' || $display_status eq 'running') {
                        $display_status = 'running';
                    }
                    
                    print sprintf("%2d. %s (%s at +%ds)\n", 
                        $display_index, 
                        $execution_entry->{node_name}, 
                        $display_status,
                        $display_timestamp);
                } else {
                    # Fallback for backward compatibility
                    $display_index++;
                    print sprintf("%2d. %s (unknown format)\n", $display_index, ref($execution_entry));
                }
            }
        } else {
            print "No execution order available (array size: " . (defined($execution_order_ref) ? scalar(@$execution_order_ref) : "undefined") . ")\n";
        }
        print "-" x 60 . "\n";
    }
    
    # Always show log directory information
    print "\n" . "-" x 60 . "\n";
    print "LOG FILES\n";
    print "-" x 60 . "\n";
    if ($BUILD_SESSION_DIR) {
        print "Build logs are available in: $BUILD_SESSION_DIR\n";
    } else {
        print "Build logs are available in: " . make_path_relative_to_caller("build/logs") . "\n";
    }
    if ($quiet || $VERBOSITY_LEVEL == 0) {
        print "Command output was redirected to individual log files only (quiet mode).\n";
        print "Check individual task logs for detailed command output.\n";
    } else {
        print "Command output was logged to individual files and displayed in terminal.\n";
        print "Check individual task logs for detailed command output.\n";
    }
    print "-" x 60 . "\n";
}



# --- Notification-Driven Execution Engine ---
# OLD EXECUTION ENGINE - COMMENTED OUT
# sub execute_notification_graph {
#     # my ($registry, $dry_run) = @_; # OLD CODE
#     
#     # Handle different execution modes
#     my $is_dry_run = 0;
#     my $is_validate = 0;
#     
#     if (defined $dry_run) {
#         if ($dry_run eq 'validate') {
#             $is_validate = 1;
#             $is_dry_run = 1; # Validation is a type of dry-run
#         } elsif ($dry_run) {
#             $is_dry_run = 1;
#         }
#     }
#     
#     # Use the registry passed in as parameter - don't create a new one!
#     
#     # CRITICAL: Process notification relationships to populate BuildNode objects
#     # This ensures both sides of notification relationships are established
#     log_debug("execute_notification_graph: processing notification relationships");
#     $registry->_process_notifications();
#     log_debug("execute_notification_graph: notification relationships processed");
#     
#     # Helper functions for dependency processing
#     
#     # DRY: Centralized function to check if a status represents successful completion
#     sub is_successful_completion_status {
#         my ($status) = @_;
#         return defined($status) && ($status eq 'done' || $status eq 'skipped' || 
#                $status eq 'validate' || $status eq 'dry-run');
#     }
#     
#     sub check_dependencies_succeeded {
#         my ($node_key, $dependencies_ref, $registry, $status_mgr, $status_ref) = @_;
#         # Fix key mismatch: dependencies_ref uses identity_key, but we're looking up with graph_key
#         # We need to find the correct key by checking if any key starts with the node's identity_key
#         my $actual_key = $node_key;
#         my @deps = [];
#         
#         # First try direct lookup
#         if (exists $dependencies_ref->{$node_key}) {
#             @deps = @{$dependencies_ref->{$node_key}};
#         } else {
#             # If not found, try to find a key that starts with the identity_key
#             my $node = $registry->get_node($node_key);
#             if ($node && $node->can('identity_key')) {
#                 my $identity_key = $node->identity_key;
#                 for my $potential_key (keys %$dependencies_ref) {
#                     if ($potential_key =~ /^\Q$identity_key\E/) {
#                         $actual_key = $potential_key;
#                         @deps = @{$dependencies_ref->{$potential_key}};
#                         log_debug("check_dependencies_succeeded: found dependencies using identity_key match: $identity_key -> $potential_key");
#                         last;
#                     }
#                 }
#             }
#         }
#         
#         # If no dependencies found, node is always ready
#         if (@deps == 0) {
#             log_debug("check_dependencies_succeeded: no dependencies found for $node_key (identity_key lookup failed)");
#             return 1; # No dependencies = always ready
#         }
#         
#         log_debug("check_dependencies_succeeded: $node_key has " . scalar(@deps) . " dependencies: " . join(", ", @deps));
#         for my $dep (@deps) {
#             my $dep_node = $registry->all_nodes->{$dep};
#             log_debug("check_dependencies_succeeded: checking dependency $dep, found node: " . ($dep_node ? "yes" : "no"));
#             if ($dep_node) {
#                 my $dep_status = $status_mgr->get_status($dep_node);
#                 log_debug("check_dependencies_succeeded: dependency $dep has status: " . ($dep_status // 'undefined'));
#                 return 0 unless $status_mgr->did_succeed($dep_node);
#         } else {
#             my $dep_status = $status_ref->{$dep} // 'undefined';
#             log_debug("check_dependencies_succeeded: dependency $dep has status in status_ref: " . $dep_status);
#             return 0 unless defined($status_ref->{$dep}) && is_successful_completion_status($status_ref->{$dep});
#         }
#     }
#     return 1;
# }
    
    # OLD FUNCTION COMMENTED OUT - REPLACED BY check_node_ready_buildnode FOR DRY PRINCIPLES
    # Reference: This function used key-based lookups and had key mismatch issues
    # The new function uses BuildNode objects directly while maintaining the same interface
    # sub check_node_ready {
    #     my ($node_key, $registry, $status_ref, $dependencies_ref, $status_mgr, $groups_ready_ref, $notified_by_ref) = @_;
    #     my $node = $registry->get_node($node_key);
    #     return 0 unless $node;
    #     
    #     log_debug("check_node_ready: checking $node_key");
    #     
    #     # 1. Check if node's own dependencies succeeded
    #     my $deps_ok = check_dependencies_succeeded($node_key, $dependencies_ref, $registry, $status_mgr, $status_ref);
    #     log_debug("check_node_ready: $node_key dependencies check result: " . ($deps_ok ? "PASSED" : "FAILED"));
    #     if (!$deps_ok) {
    #         log_debug("check_node_ready: $node_key is NOT ready (dependencies failed)");
    #         return 0;
    #     }
    #     
    #     # 2. Check if any parent group is ready (OR logic)
    #     # Define check_parent_group_ready locally to access the right parameters
    #     my $check_parent_group_ready = sub {
    #         my ($node_key, $registry, $status_ref, $groups_ready_ref) = @_;
    #         my $node = $registry->get_node($node_key);
    #         return 1 unless $node; # No node found, assume ready
    #         
    #         # Check if this is a root node (no parents) - root nodes are always ready
    #         if ($node->can('get_parents')) {
    #             my @parents = $node->get_parents();
    #             if (@parents == 0) {
    #                 log_debug("check_parent_group_ready: $node_key is a root node (no parents), always ready");
    #                 return 1;
    #         }
    #     }
    #     
    #     # Check if any parent is in groups_ready AND respects continue_on_error logic
    #     for my $parent ($node->get_parents()) {
    #         my $parent_key = $parent->key;
    #         
    #         # Check if parent is in groups_ready
    #         if (exists $groups_ready_ref->{$parent_key}) {
    #             log_debug("check_parent_group_ready: $node_key has parent $parent_key in groups_ready");
    #             
    #         # If parent has continue_on_error = false, check its status
    #         if (defined($parent->continue_on_error) && !$parent->continue_on_error) {
    #             # Strict parent (coe = false) must be in successful state to coordinate
    #             my $parent_status = $status_ref->{$parent_key};
    #             if (!is_successful_completion_status($parent_status)) {
    #                 log_debug("check_parent_group_ready: $node_key parent $parent_key has coe=false and status '$parent_status', not ready");
    #                 next; # Try next parent
    #             } else {
    #                 log_debug("check_parent_group_ready: $node_key parent $parent_key has coe=false and successful status '$parent_status', ready");
    #                 return 1;
    #             }
    #         } else {
    #             # Forgiving parent (coe = true or undefined) can coordinate regardless of status
    #             log_debug("check_parent_group_ready: $node_key parent $parent_key has coe=true or undefined, ready");
    #             return 1;
    #         }
    #     }
    # }
    #     
    #     log_debug("check_parent_group_ready: $node_key no parents ready (either not in groups_ready or strict parents failed)");
    #         return 0;
    #     };
    #     
    #     my $parent_ready = $check_parent_group_ready->($node_key, $registry, $status_ref, $groups_ready_ref);
    #     log_debug("check_node_ready: $node_key parent group check result: " . ($parent_ready ? "PASSED" : "FAILED"));
    #     if (!$parent_ready) {
    #         log_debug("check_node_ready: $node_key is NOT ready (no parents ready)");
    #         return 0;
    #     }
    #     
    #     # 3. Check if node is blocked by other nodes
    #     my $not_blocked = check_node_not_blocked($node_key, $registry, $status_ref);
    #     log_debug("check_node_ready: $node_key blocked check result: " . ($not_blocked ? "PASSED" : "FAILED"));
    #     if (!$not_blocked) {
    #         log_debug("check_node_ready: $node_key is NOT ready (blocked by other nodes)");
    #         return 0;
    #     }
    #     
    #     # 4. Check if notification dependencies are satisfied
    #     my $notifications_ok = check_notifications_succeeded($node_key, $notified_by_ref, $registry, $status_mgr, $status_ref);
    #     log_debug("check_node_ready: $node_key notifications check result: " . ($notifications_ok ? "PASSED" : "FAILED"));
    #     if (!$notifications_ok) {
    #         log_debug("check_node_ready: $node_key is NOT ready (notification dependencies not satisfied)");
    #         return 0;
    #     }
    #     
    #     log_debug("check_node_ready: $node_key is READY to execute");
    #     return 1;
    # }

# NEW: BuildNode-based version of check_node_ready (DRY principle)

    
    # NEW: BuildNode-based version of transition_node (DRY principle)
    
    # OLD FUNCTION COMMENTED OUT - REPLACED BY check_notifications_succeeded_buildnode FOR DRY PRINCIPLES
    # Reference: This function had key mismatch issues between identity_key and graph_key
    # The new function uses BuildNode objects directly while maintaining the same interface
    # sub check_notifications_succeeded {
    #     my ($node_key, $notified_by_ref, $registry, $status_mgr, $status_ref) = @_;
    #     my @notifiers = @{$notified_by_ref->{$node_key} // []};
    #     for my $notifier (@notifiers) {
    #         my $notifier_node = $registry->all_nodes->{$notifier};
    #         if ($notifier_node) {
    #             return 0 unless $status_mgr->did_succeed($notifier_node);
    #         } else {
    #             return 0 unless is_successful_completion_status($status_ref->{$notifier});
    #         }
    #     }
    #     return 1;
    # }
    
    # OLD FUNCTION COMMENTED OUT - REPLACED BY check_node_not_blocked_buildnode FOR DRY PRINCIPLES
    # Reference: This function had key mismatch issues between identity_key and graph_key
    # The new function uses BuildNode objects directly while maintaining the same interface
    # sub check_node_not_blocked {
    #     my ($node_key, $registry, $status_ref) = @_;
    #     my $node = $registry->get_node($node_key);
    #     return 1 unless $node; # No node found, assume not blocked
    #     
    #     # Check if this node is blocked by any other nodes
    #     my @blockers = $node->get_node_blockers();
    #     if ($VERBOSITY_LEVEL >= 3) {
    #         if (@blockers > 0) {
    #             log_debug("check_node_not_blocked: $node_key has " . scalar(@blockers) . " blockers: " . join(", ", @blockers));
    #         }
    #     }
    #     
    #     for my $blocker_key (@blockers) {
    #         # A node is blocked if any of its blockers are not 'done' or 'skipped'
    #         my $blocker_status = $status_ref->{$blocker_key};
    #         if (!exists $status_ref->{$blocker_key} || 
    #             !is_successful_completion_status($blocker_status)) {
    #             log_debug("check_node_not_blocked: $node_key is BLOCKED by $blocker_key (status: " . ($blocker_status // 'undefined') . ")");
    #             return 0;
    #         }
    #     }
    #     
    #         if (@blockers > 0) {
    #             log_debug("check_node_not_blocked: $node_key is NOT blocked (all blockers done/skipped)");
    #         }
    #     return 1; # No blockers, or all blockers are done/skipped
    #     }
    

    
    # NEW: BuildNode-based helper functions (DRY principle)
    
    
    
    
    # Process ready_pending_parent queue and move nodes to appropriate queues
    # OLD FUNCTION COMMENTED OUT - REPLACED BY process_ready_pending_parent_buildnode FOR DRY PRINCIPLES
    # Reference: This function used key-based lookups and mixed key/BuildNode approaches
    # The new function uses BuildNode objects directly while maintaining the same interface
    # sub process_ready_pending_parent {
    #     my ($registry, $status_ref, $groups_ready_ref, $ready_queue_ref, $status_mgr_ref, $ready_pending_parent_ref) = @_;
    #     my @remaining;
    #     my $moved_count = 0;
    #     
    #     # Group nodes by their parent group for sequential processing
    #     my %parent_children;
    #     my @root_level_nodes; # Nodes with no parents (root level)
    #     
    #     for my $node_key (@$ready_pending_parent_ref) {
    #         my $node = $registry->get_node($node_key);
    #         next unless $node;
    #         
    #         # Find the immediate parent group
    #         my $parent_key = _find_immediate_parent_group($node_key, $registry);
    #         log_debug("process_ready_pending_parent: node $node_key has parent_key: " . ($parent_key // 'undef'));
    #         if ($parent_key) {
    #             $parent_children{$parent_key} ||= [];
    #             push @{$parent_children{$parent_key}}, $node_key;
    #         } else {
    #             # No parent group = root level node, always ready
    #             push @root_level_nodes, $node_key;
    #             log_debug("process_ready_pending_parent: identified $node_key as root-level node");
    #         }
    #     }
    #     
    #     # FIRST PASS: Copy structurally ready tasks to groups_ready (they stay in rpp)
    #     for my $node_key (@$ready_pending_parent_ref) {
    #         my $node = $registry->get_node($node_key);
    #         next unless $node;
    #         
    #         # Check if this node is structurally ready (no external dependencies)
    #         if ($node->can('get_external_dependencies')) {
    #             my @ext_deps = @{ $node->get_external_dependencies() };
    #             if (@ext_deps == 0) {
    #                 # No external dependencies = structurally ready
    #                 if ($node->is_group) {
    #                     # Group nodes get copied to groups_ready for coordination
    #                     $groups_ready_ref->{$node_key} = 1;
    #                     log_debug("process_ready_pending_parent: group $node_key is structurally ready, copied to groups_ready");
    #                 } else {
    #                     # Task nodes get copied to groups_ready for coordination
    #                     $groups_ready_ref->{$node_key} = 1;
    #                     log_debug("process_ready_pending_parent: task $node_key is structurally ready, copied to groups_ready");
    #                 }
    #             } else {
    #                 log_debug("process_ready_pending_parent: $node_key has " . scalar(@ext_deps) . " external dependencies, not structurally ready");
    #             }
    #         } else {
    #             # No external dependencies method = assume structurally ready
    #             if ($node->is_group) {
    #                 $groups_ready_ref->{$node_key} = 1;
    #                     log_debug("process_ready_pending_parent: group $node_key (no ext deps method) copied to groups_ready");
    #                 } else {
    #                     $groups_ready_ref->{$node_key} = 1;
    #                     log_debug("process_ready_pending_parent: task $node_key (no ext deps method) copied to groups_ready");
    #                 }
    #             }
    #         }
    #     }
    #     
    #     # SECOND PASS: Move dependency-free tasks with ready parents to ready queue
    #     # Use array indices to avoid modification during iteration issues
    #     my $i = 0;
    #     log_debug("process_ready_pending_parent: SECOND PASS - processing " . scalar(@$ready_pending_parent_ref) . " nodes");
    #     
    #     while ($i < @$ready_pending_parent_ref) {
    #         my $node_key = $ready_pending_parent_ref->[$i];
    #         my $node = $registry->get_node($node_key);
    #         
    #         log_debug("process_ready_pending_parent: examining node $node_key");
    #         if ($node) {
    #             log_debug("process_ready_pending_parent: $node_key - type: " . ($node->type // 'undefined') . ", is_group: " . ($node->is_group ? 'true' : 'false'));
    #         } else {
    #             log_debug("process_ready_pending_parent: $node_key - node is undefined");
    #         }
    #         
    #         if (!$node) {
    #             log_debug("process_ready_pending_parent: $node_key - no node found, skipping");
    #             $i++;
    #             next;
    #         }
    #         
    #         # Skip if this node is not in groups_ready (not structurally ready)
    #         unless (exists $groups_ready_ref->{$node_key}) {
    #             log_debug("process_ready_pending_parent: $node_key - not in groups_ready, skipping");
    #             $i++;
    #             next;
    #         }
    #         
    #         log_debug("process_ready_pending_parent: $node_key - in groups_ready, checking dependencies");
    #         
    #         # Check if this node has no dependencies
    #         my @dependencies = @{ $node->dependencies || [] };
    #         if (@dependencies == 0) {
    #             # No dependencies = ready for execution (all nodes treated equally)
    #             push @$ready_queue_ref, $node_key;
    #             transition_node($node_key, 'pending', $registry, $status_mgr_ref, $status_ref);
    #             log_debug("process_ready_pending_parent: $node_key has no dependencies, moved to ready");
    #             
    #             # Remove this node from ready_pending_parent by splicing it out
    #             splice(@$ready_pending_parent_ref, $i, 1);
    #             log_debug("process_ready_pending_parent: removed $node_key from ready_pending_parent");
    #             $moved_count++;
    #             # Don't increment $i since we removed an element
    #         } else {
    #             # Has dependencies - check if all dependencies are satisfied
    #             my $all_deps_satisfied = 1;
    #             for my $dep (@dependencies) {
    #                 # Use graph_key for status lookup (same pattern as notifications and dependency resolution)
    #                 my $dep_key = $dep->key;
    #                 my $dep_status = $status_ref->{$dep_key};
    #                 if (!exists $status_ref->{$dep_key} || 
    #                     !is_successful_completion_status($dep_status)) {
    #                     $all_deps_satisfied = 0;
    #                     log_debug("process_ready_pending_parent: $node_key dependency $dep_key not satisfied (status: " . ($dep_status // 'undefined') . ")");
    #                     last;
    #                     }
    #                 }
    #                 
    #                 if ($all_deps_satisfied) {
    #                     # All dependencies satisfied = ready for execution (all nodes treated equally)
    #                     push @$ready_queue_ref, $node_key;
    #                     transition_node($node_key, 'pending', $registry, $status_mgr_ref, $status_ref);
    #                     log_debug("process_ready_pending_parent: $node_key all dependencies satisfied, moved to ready");
    #                     
    #                     # Remove this node from ready_pending_parent by splicing it out
    #                     splice(@$ready_pending_parent_ref, $i, 1);
    #                     log_debug("process_ready_pending_parent: removed $node_key from ready_pending_parent");
    #                     $moved_count++;
    #                     # Don't increment $i since we removed an element
    #                 } else {
    #                     log_debug("process_ready_pending_parent: $node_key has unsatisfied dependencies, stays in ready_pending_parent");
    #                     $i++;
    #                 }
    #             }
    #         }
    #         
    #         # No need to modify ready_pending_parent - nodes stay there until moved to ready
    #         # The COPY phase doesn't remove nodes, only the MOVE phase does
    #         # This preserves the queue structure naturally
    #         
    #         log_debug("process_ready_pending_parent: moved $moved_count nodes, " . scalar(@$ready_pending_parent_ref) . " remaining");
    #         return $moved_count;
    #     }
    # }
    
    # NEW: BuildNode-based version of process_ready_pending_parent (DRY principle)
    # This function now works entirely with BuildNode objects and uses helper functions


# --- Build Summary Function ---


sub main {
    # Debug output removed for cleaner logs
    
    $cfg = load_config();

    # Global status manager already initialized before module loading
    log_debug("Main: Global STATUS_MANAGER already initialized");

    # Apply defaults from config
    my $default_target = $cfg->{default_target} // 'all';
    my $global_continue_on_error = $cfg->{continue_on_error} // 0;
    my $validate_on_build = $cfg->{validate_on_build} // 0;
    my $default_logging_level = $cfg->{logging}{default_level} // 'normal';

    # Apply default logging level if not overridden by CLI
    if (!$quiet && !$verbose && !$debug) {
        if ($default_logging_level eq 'quiet') {
            $VERBOSITY_LEVEL = 0;
        } elsif ($default_logging_level eq 'normal') {
            $VERBOSITY_LEVEL = 1;
        } elsif ($default_logging_level eq 'verbose') {
            $VERBOSITY_LEVEL = 2;
        } elsif ($default_logging_level eq 'debug') {
            $VERBOSITY_LEVEL = 3;
        }
        
        # Sync BuildUtils verbosity level when set from config
        if (defined $VERBOSITY_LEVEL) {
            $BuildUtils::VERBOSITY_LEVEL = $VERBOSITY_LEVEL;
        }
    }
    
    # Debug: log the verbosity level being used
    if (defined $VERBOSITY_LEVEL && $VERBOSITY_LEVEL >= 3) {
        log_debug("Main: default_logging_level: " . ($default_logging_level // 'undef') . ", VERBOSITY_LEVEL: $VERBOSITY_LEVEL");
    }

    # Handle early exit cases
    if ($print_build_order) {
        if ($VERBOSITY_LEVEL >= 1) {
            print "BUILD ORDER TREE\n================\n";
            # Print build order trees for each group
            for my $group (sort keys %{$cfg->{build_groups} // {}}) {
                print_build_order_tree($cfg, $group);
            }
        }
        return 0;
    }
    
    if ($print_build_order_json) {
        use JSON;
        my @all_trees;
        for my $group (sort keys %{$cfg->{build_groups} // {}}) {
            my $tree = build_order_json($cfg, $group);
            push @all_trees, $tree if $tree;
        }
        print to_json(\@all_trees, { pretty => 1 });
        return 0;
    }

    if ($list_targets) {
        print "\nAvailable Platforms:\n";
        for my $platform (@{$cfg->{platforms} // []}) {
            my $name = $platform->{name};
            my $description = $platform->{description} || "";
            my $desc_str = $description ? " - $description" : "";
            print "  - $name (platform)$desc_str\n";
        }
        
        print "\nAvailable Tasks:\n";
        for my $task (@{$cfg->{tasks} // []}) {
            my $name = $task->{name};
            my $description = $task->{description} || "";
            my $args_str = "";
            if ($task->{args}) {
                my @args = map { "$_=$task->{args}->{$_}" } sort keys %{$task->{args}};
                $args_str = " [" . join(", ", @args) . "]" if @args;
            }
            my $desc_str = $description ? " - $description" : "";
            print "  - $name (task)$args_str$desc_str\n";
        }
        
        print "\nAvailable Build Groups:\n";
        for my $group (sort keys %{$cfg->{build_groups} // {}}) {
            my $group_config = $cfg->{build_groups}->{$group};
            my $description = $group_config->{description} || "";
            my $desc_str = $description ? " - $description" : "";
            print "  - $group (group)$desc_str\n";
        }
        print "\n";
        return 0;
    }

    # --- Main execution path (unified for all modes) ---
    # WHAT: Single execution path that handles all targets and modes
    # HOW: Determines target list from arguments, then executes each target
    # WHY: Eliminates code duplication and ensures consistent behavior across all modes
    # PUBLIC: This is the main execution interface for all build modes

    # Determine target list based on arguments (priority: display > validate > target > default)
    my @target_list;
    if ($display) {
        @target_list = ($display);
        $IS_VALIDATE = 1; # Display mode implies validation mode
        log_info("Display mode: processing target: $display");
    } elsif ($validate && !$display) {
        @target_list = get_all_available_targets($cfg);
        $IS_VALIDATE = 1;
        log_info("Validation mode: processing " . scalar(@target_list) . " targets");
    } elsif ($target) {
        @target_list = ($target);
        log_info("Target mode: processing target: $target");
    } else {
        @target_list = ($default_target);
        log_info("Default mode: processing target: $default_target");
    }

    # Initialize build session directory for this build run
    init_build_session_dir();
    
    # Execute each target in the list
    my @all_results = ();
    my @all_execution_orders = ();
    my @all_durations = ();

    for my $current_target (@target_list) {
        log_info("Processing target: $current_target");
        
        # Validate target and warn if not found
        unless ($display) {
            my ($target_exists, $suggestion) = validate_target_with_suggestions($current_target, $cfg);
            unless ($target_exists) {
                log_warn("Target '$current_target' not found in build configuration.");
                if ($suggestion) {
                    log_warn($suggestion);
                }
                log_warn("Skipping target '$current_target'. Run 'dbs-build --list-targets' to see available targets.");
                next;
            }
        }
        
        # Initialize fresh state for this target
        @READY_PENDING_PARENT_NODES = ();
        @READY_QUEUE_NODES = ();
        %GROUPS_READY_NODES = ();
        $REGISTRY = BuildNodeRegistry->new;
        
        # Build graph and populate registry
        my $global_defaults = extract_global_vars($cfg);
        my $root_node = build_graph_with_worklist($current_target, {}, $cfg, $global_defaults, $REGISTRY);
        # Registry is already fully populated by build_graph_with_worklist
        
        # Execute the target (single execution path, mode-aware behavior)
        my ($result, $execution_order_ref, $duration_ref) = execute_build_nodes($current_target);
        
        # Store results
        push @all_results, $result;
        push @all_execution_orders, $execution_order_ref;
        push @all_durations, $duration_ref;
        
        # Show detailed summary if in display mode, or execution order for single targets
        # Print summary for: display mode, explicit target, dry-run, or default target (single target, not in validation mode)
        if (($display && $current_target eq $display) || $target || $dry_run || (!$IS_VALIDATE && @target_list == 1)) {
            print_build_summary($execution_order_ref, $duration_ref);
        }
        
        # Show minimal summary for this target
        if ($result) {
            log_success("Target '$current_target' completed successfully");
        } else {
            log_error("Target '$current_target' failed");
        }
    }

    # Show composite summary if in validation mode
    if ($IS_VALIDATE) {
        my $success_count = grep { $_ } @all_results;
        my $total_count = scalar(@all_results);
        log_info("Validation complete: $success_count/$total_count targets succeeded");
        
        if ($success_count < $total_count) {
            log_error("Some targets failed validation");
            return 1;
        } else {
            log_success("All targets validated successfully");
        }
    }

    # Return success/failure status
    my $overall_success = all { $_ } @all_results;
    return $overall_success ? 0 : 1;
}

# --- Script Entry Point ---
# Call the main function and exit with its return code
exit(main());

