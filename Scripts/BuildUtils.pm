package BuildUtils;

use strict;
use warnings;
use Exporter 'import';
use Term::ANSIColor;
use Carp qw(croak);
use Data::Dumper;
use List::Util qw(all min);
use Scalar::Util qw(blessed);
our $VERBOSITY_LEVEL = 1; # 0=quiet, 1=normal, 2=verbose, 3=debug

# Global queue variables are declared in build.pl - access them from main package

=head1 NAME
BuildUtils - Utility functions for Distributed Build System (DBS)
=cut

=head1 SYNOPSIS
  use BuildUtils qw(merge_args node_key);
=cut

# --- Normalize arguments to consistent hash format ---
# WHAT: Converts various argument formats (array, scalar, hash) into a standardized hash reference
# HOW: Handles arrays by converting to arg1, arg2, etc., scalars to arg1, preserves existing hashes
# WHY: Ensures consistent argument handling across the build system regardless of input format
# INTERNAL: This is an internal utility function, not intended for direct use by build scripts
sub read_args {
    my ($args) = @_;
    if (ref($args) eq 'ARRAY') {
        my %h;
        for my $i (0..$#$args) {
            $h{"arg".($i+1)} = $args->[$i];
        }
        return \%h;
    } elsif (!ref($args) && defined $args) {
        return { arg1 => $args };
    } elsif (ref($args) eq 'HASH') {
        # Flatten nested hash structures into simple key-value pairs
        my %flattened;
        _flatten_hash($args, \%flattened);
        return \%flattened;
    } else {
        return {};
    }
}

# --- Helper function to flatten nested hash structures ---
# WHAT: Recursively flattens nested hash structures into simple key-value pairs
# HOW: Converts nested keys like {a: {b: "c"}} into {a_b: "c"}
# WHY: Ensures consistent internal storage format for arguments regardless of config input format
# INTERNAL: This is an internal helper function used by read_args, not intended for direct use
sub _flatten_hash {
    my ($hash, $result, $prefix) = @_;
    $prefix ||= '';
    
    for my $key (sort keys %$hash) {
        my $value = $hash->{$key};
        my $new_key = $prefix ? "${prefix}_${key}" : $key;
        
        if (ref($value) eq 'HASH') {
            # Recursively flatten nested hashes
            _flatten_hash($value, $result, $new_key);
        } elsif (ref($value) eq 'ARRAY') {
            # Convert arrays to sorted string representation
            $result->{$new_key} = '[' . join(',', sort @$value) . ']';
        } else {
            # Store primitive values as-is
            $result->{$new_key} = $value;
        }
    }
}



# --- Merge arguments with selective global merging ---
# PUBLIC: This function is part of the public API and can be used by build scripts
# WHAT: Merges node arguments with parent arguments and selectively extracts needed globals
# HOW: Analyzes command for ${variable} references, extracts only needed globals, merges hierarchy
# WHY: Ensures nodes only get the arguments they need while preserving all node-specific args
# NOTE: This function is backward compatible - it can handle both old and new calling patterns
sub merge_args {
    my @args = @_;
    
    # Detect calling pattern
    if (@args == 1 && ref($args[0]) eq 'ARRAY') {
        # Old pattern: merge_args([$arg1, $arg2, ...]) - COMMENTED OUT FOR REFACTORING
        # return _merge_args_list(@{$args[0]});
        die "Old pattern merge_args([...]) is deprecated. Use new pattern with command-based merging.";
    } elsif (@args == 4 && ref($args[0]) eq '' && (ref($args[1]) eq 'HASH' || ref($args[1]) eq 'ARRAY' || !defined($args[1])) && (ref($args[2]) eq 'HASH' || !defined($args[2])) && ref($args[3]) eq 'HASH') {
        # New pattern: merge_args($command, $node_args, $parent_args, $global_vars)
        my ($command, $node_args, $parent_args, $global_vars) = @args;
        return _merge_args_with_command($command, $node_args, $parent_args, $global_vars);
    } else {
        # Old pattern: merge_args($arg1, $arg2, ...) - COMMENTED OUT FOR REFACTORING
        # return _merge_args_list(@args);
        die "Old pattern merge_args(\$arg1, \$arg2, ...) is deprecated. Use new pattern with command-based merging.";
    }
}

# --- Backward compatible list-based argument merging ---
# WHAT: Handles the old calling pattern for backward compatibility
# HOW: Merges arguments in order (later overrides earlier)
# WHY: Maintains compatibility with existing code while new code can use command-based merging
# INTERNAL: This is an internal helper function used by merge_args, not intended for direct use
sub _merge_args_list {
    my @args_list = @_;
    my %merged = ();
    
    # Merge in order: later arguments override earlier ones
    for my $args (@args_list) {
        my $parsed = read_args($args);
        %merged = (%merged, %$parsed) if $parsed;
    }
    
    # Return the merged arguments (already flattened by read_args)
    return \%merged;
}

# --- Command-based argument merging with selective global extraction ---
# WHAT: Merges arguments with selective global merging based on command usage
# HOW: Analyzes command for ${variable} references, extracts only needed globals, merges hierarchy
# WHY: Ensures nodes only get the arguments they need while preserving all node-specific args
# INTERNAL: This is an internal helper function used by merge_args, not intended for direct use
sub _merge_args_with_command {
    my ($command, $node_args, $parent_args, $global_vars) = @_;
    $command ||= '';
    $node_args ||= {};
    $parent_args ||= {};
    $global_vars ||= {};
    
    # Start with node arguments (highest priority)
    my %merged = ();
    if ($node_args && ref($node_args) eq 'HASH') {
        %merged = %$node_args;
    } elsif ($node_args && ref($node_args) eq 'ARRAY') {
        # Convert array to hash if needed
        %merged = map { $_ => 1 } @$node_args;
    }
    
    # Merge in parent arguments (node args override parent args)
    if ($parent_args && ref($parent_args) eq 'HASH') {
        %merged = (%merged, %$parent_args);
    }
    
    # Extract only the globals that are referenced in the command
    my %needed_globals = _extract_needed_globals($command, $global_vars);
    
    # Merge in needed globals (node/parent args override globals)
    %merged = (%merged, %needed_globals);
    
    # Normalize the final merged arguments using read_args
    return read_args(\%merged);
}

# --- Extract only the globals that are referenced in a command ---
# WHAT: Analyzes command for ${variable} references and extracts only those globals
# HOW: Parses command for ${var} patterns, extracts nested globals, flattens to key-value pairs
# WHY: Ensures nodes only get the globals they actually need, not the entire global variables hash
# INTERNAL: This is an internal helper function used by merge_args, not intended for direct use
sub _extract_needed_globals {
    my ($command, $global_vars) = @_;
    my %needed_globals;
    
    # Find all ${variable} references in the command
    while ($command =~ /\$\{([^}]+)\}/g) {
        my $var_path = $1;
        my $value = _extract_nested_value($global_vars, $var_path);
        if (defined $value) {
            # Flatten the nested path to a simple key
            my $flat_key = _flatten_key_path($var_path);
            $needed_globals{$flat_key} = $value;
        }
    }
    
    return %needed_globals;
}

# --- Extract a nested value from a hash using dot notation ---
# WHAT: Extracts values from nested hash structures using dot notation (e.g., "artifacts.retention.type")
# HOW: Splits path by dots, traverses nested hashes, returns the final value
# WHY: Enables access to nested global variables like ${artifacts.retention.type}
# INTERNAL: This is an internal helper function used by _extract_needed_globals, not intended for direct use
sub _extract_nested_value {
    my ($hash, $path) = @_;
    my @parts = split(/\./, $path);
    my $current = $hash;
    
    for my $part (@parts) {
        return undef unless ref($current) eq 'HASH' && exists $current->{$part};
        $current = $current->{$part};
    }
    
    return $current;
}

# --- Flatten a dot-notation path to a simple key ---
# WHAT: Converts nested paths like "artifacts.retention.type" to flat keys like "artifacts_retention_type"
# HOW: Replaces dots with underscores to create consistent, flat key names
# WHY: Ensures consistent key naming for arguments regardless of how they're referenced in commands
# INTERNAL: This is an internal helper function used by _extract_needed_globals, not intended for direct use
sub _flatten_key_path {
    my ($path) = @_;
    return $path =~ s/\./_/gr;
}

# --- Process notification target ---
# WHAT: Processes a notification target and returns the target node and key
# HOW: Extracts key from BuildNode notification target (notifications are already BuildNode references)
# WHY: Enables notification relationship processing in BuildNodeRegistry
# INTERNAL: This is an internal helper function used by BuildNodeRegistry, not intended for direct use
sub process_notification_target {
    my ($notify, $registry) = @_;
    
    # $notify is already a BuildNode reference from get_notifies methods
    # Just extract the key from it
    if (ref($notify) && $notify->can('key')) {
        my $target_key = $notify->key;
        return ($notify, $target_key);
    } else {
        log_debug("process_notification_target: Invalid notification target: " . ref($notify));
        return (undef, undef);
    }
}

# --- Get canonical node key for execution and tracking ---
# WHAT: Retrieves the canonical key for a BuildNode object used throughout the build system
# HOW: Delegates to the node's key method, validates that the argument is a BuildNode object
# WHY: Provides the single source of truth for node identification in execution, notifications, and cycle detection
# PUBLIC: This function is part of the public API and can be used by build scripts
sub node_key {
    my ($node) = @_;
    croak "node_key: argument is not a BuildNode object" unless ref($node) && $node->can('key');
    return $node->key;
}

# --- Get canonical key from BuildNode object ---
# WHAT: Retrieves the canonical key from a BuildNode object with validation
# HOW: Validates the argument is a BuildNode object, calls the node's key method
# WHY: Provides safe access to node keys with proper error checking for invalid arguments
# PUBLIC: This function is part of the public API and can be used by build scripts
sub get_key_from_node {
    my ($node) = @_;
    croak "get_key_from_node: argument is not a BuildNode object" unless ref($node) && $node->can('name');
    # Return the BuildNode reference directly instead of generating a key
    return $node;
}

# --- Check if a status represents successful completion ---
# WHAT: Determines if a node status indicates successful completion
# HOW: Checks if status is 'done', 'skipped', 'validate', or 'dry-run'
# WHY: Provides consistent status checking across the build system
# PUBLIC: This function is part of the public API and can be used by build scripts
sub is_successful_completion_status {
    my ($status) = @_;
    return defined($status) && ($status eq 'done' || $status eq 'skipped' || 
           $status eq 'validate' || $status eq 'dry-run' || $status eq 'noop');
}

# --- Check if any parent of a node is in the groups_ready queue ---
# WHAT: Determines if any parent of a node is ready (exists in groups_ready hash)
# HOW: Iterates through all parents of a node, returns true if any parent key exists in groups_ready
# WHY: Enables proper parent readiness checking for nodes with multiple parents in the three-queue system
# PUBLIC: This function is part of the public API and can be used by build scripts
sub check_any_parent_in_groups_ready {
    my ($node, $groups_ready_ref) = @_;
    croak "check_any_parent_in_groups_ready: first argument is not a BuildNode object" unless ref($node) && $node->can('parents');
    croak "check_any_parent_in_groups_ready: second argument is not a hash reference" unless ref($groups_ready_ref) eq 'HASH';
    
    my @parents = @{$node->parents || []};
    
    # Root nodes (no parents) are always ready to coordinate
    return 1 unless @parents;
    
    # All nodes (including dependency groups) follow the same coordination rules
    # They must wait for their immediate parent to be in groups_ready
    
    # Check if ANY parent is in groups_ready (OR logic)
    for my $parent (@parents) {
        if (ref($parent) && $parent->can('key')) {
            my $parent_key = $parent->key;
            if (exists $groups_ready_ref->{$parent_key}) {
                return 1; # Found a ready parent
            }
        }
    }
    
    return 0; # No parents are ready
}

# --- Generate canonical node key from config entry and arguments ---
# WHAT: Creates a unique, canonical key for a node based on its config entry, arguments, and global defaults
# HOW: Analyzes command for used globals, merges with arguments, generates key with instance specification
# WHY: Ensures consistent node identification across the build system with proper argument handling
# PUBLIC: This is the primary public interface for generating canonical node keys
sub canonical_node_key {
    my ($entry, $args, $global_defaults, $instance_spec, $relationship) = @_;
    $args ||= {};
    $global_defaults ||= {};
    
    # Only include global defaults that are actually used by the command or argument names
    my %used_globals;
    my $command = $entry->{command} // $entry->{build_command} // '';
    my $name = $entry->{name};
    
    # Check which global defaults are referenced in the command
    for my $global_key (keys %$global_defaults) {
        my $global_value = $global_defaults->{$global_key};
        # Check if the global is referenced in the command (${key} or $key)
        if ($command =~ /\$\{?$global_key\}?/) {
            $used_globals{$global_key} = $global_value;
        }
        # Check if the global is referenced in argument names (arg1, arg2, etc.)
        elsif ($global_key =~ /^arg\d+$/ && exists $args->{$global_key}) {
            $used_globals{$global_key} = $global_value;
        }
    }
    
    # Merge only used globals with provided args (args override globals)
    my %merged_args = (%used_globals, %{ $args // {} });
    
    # Generate key directly without creating a temporary BuildNode object
    my $key = generate_node_key($name, \%merged_args, $entry);
    
    # Include explicit instance in canonical key if specified
    # This allows multiple instances of the same task with different instance IDs
    if ($instance_spec) {
        $key .= "|instance=$instance_spec";
    }
    
    # For nodes that are NOT children of dependency groups, include relationship context to ensure unique keys
    # This allows the same logical task to execute multiple times in different contexts
    # Note: We can't check parent here since this function doesn't have access to parent context
    # The deduplication logic in get_or_create_node will handle this correctly
    
    # This ensures fan-in semantics where multiple dependents can reference
    # the same logical task and get the same node instance (for dependencies only)
    return $key;
}

# --- Generate node key from name, arguments, and config entry ---
# WHAT: Creates a unique key for a node by analyzing command variables and argument usage
# HOW: Scans commands, notifications, and children for variable usage, includes only relevant arguments in key
# WHY: Ensures nodes with different arguments get different keys while maintaining consistency
# INTERNAL: This is an internal utility called by canonical_node_key, not intended for direct use
sub generate_node_key {
    my ($name, $args, $entry) = @_;
    $args ||= {};
    $entry ||= {};
    
    my $key = $name;
    my %used_args;
    
    # Find all variables used in commands
    for my $field (qw(command build_command)) {
        next unless $entry->{$field};
        my $cmd = $entry->{$field};
        while ($cmd =~ /\$\{(\w+)\}/g) { $used_args{$1} = 1; }
        while ($cmd =~ /\$arg(\d+)/g) { $used_args{"arg$1"} = 1; }
    }
    
    # Find all variables used in all notification types (notifies, notifies_on_success, notifies_on_failure)
    for my $notif_field (qw(notifies notifies_on_success notifies_on_failure)) {
        next unless $entry->{$notif_field};
        for my $notify (@{ $entry->{$notif_field} }) {
            if ($notify->{args} && ref $notify->{args} eq 'HASH') {
                $used_args{$_} = 1 for keys %{ $notify->{args} };
            }
            if ($notify->{args_from} && $notify->{args_from} eq 'self' && $args) {
                $used_args{$_} = 1 for keys %$args;
            }
        }
    }
    
    # Find all variables used in children
    if ($entry->{children}) {
        for my $child (@{ $entry->{children} }) {
            if ($child->{args} && ref $child->{args} eq 'HASH') {
                $used_args{$_} = 1 for keys %{ $child->{args} };
            }
        }
    }
    
    # Include only relevant args in the key
    if ($args && ref $args eq 'HASH') {
        my @relevant = grep { exists $args->{$_} } sort keys %used_args;
        if (@relevant) {
            $key .= '|' . join(',', map { "$_=$args->{$_}" } @relevant);
        }
    }
    
    # Include explicit instance in canonical key if specified
    # This allows multiple instances of the same task with different instance IDs
    
    return $key;
}

# --- Get existing node or create new one with worklist expansion ---
# WHAT: Looks up a node by canonical key, creates it if not found, adds related nodes to worklist
# HOW: Uses canonical key for lookup, creates node if missing, adds children/dependencies/notifications to worklist
# WHY: Ensures single node instance per canonical key while enabling worklist-driven graph expansion
# INTERNAL: This is an internal function used by build_graph_with_worklist, not intended for direct use
sub get_or_create_node {
    my ($name, $args, $parent_key, $parent_node, $relationship, $node_global_defaults, $registry, $task_by_name, $platform_by_name, $group_by_name, $cfg, $global_defaults, $worklist_ref, $instance_spec, $dedupe_nodes) = @_;
    
    # Look up existing node by name and args first - but only when deduplication is enabled
    # Regular tasks should be allowed to exist in multiple parent contexts
    my $existing_node;
    if ($dedupe_nodes) {
        $existing_node = $registry->get_node_by_name_and_args($name, $args);
        if ($existing_node) {
            log_debug("Found existing deduplicated node: $name");
            return $existing_node;
        }
    }
    
    # Load the config entry to create new node
    my $entry = load_config_entry($name, $task_by_name, $platform_by_name, $group_by_name, $cfg, $global_defaults);
    return undef unless $entry;
    
    # Create merged args from provided args
    my %merged_args = %{ $args // {} };
    
    # Create a new node
    log_debug("Creating new node: $name");
    # Add "dep" flag to canonical key for deduplicated nodes to enable deduplication
    my $canonical_key = $dedupe_nodes ? "$name|dep" : $name;
    my $node = build_and_register_node($entry, \%merged_args, $registry, $task_by_name, $platform_by_name, $group_by_name, $canonical_key, $dedupe_nodes);
    return undef unless $node;
    
    # Add new node to worklist for processing
    if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
        log_debug("Adding to worklist: " . $node->name . " (type: " . ($node->type // 'unknown') . ")");
    }
    
    
    push @$worklist_ref, [$node, $parent_node, $relationship, $node_global_defaults, $instance_spec];
    
    # Relationships are processed in the main relationship processing section below
    # No need to process them here when attaching to parent
    
    # COMMENTED OUT: Add related nodes to worklist for later processing - GOCN should not process relationships
    # This ensures the worklist-driven approach handles all recursive expansion
    # if ($entry->{targets} && ref($entry->{targets}) eq 'ARRAY') {
    #     for my $target (@{ $entry->{targets} }) {
    #         my ($child_name, $child_args, $child_instance);
    #         if (ref($target) eq 'HASH') {
    #             $child_name = $target->{name};
    #             $child_args = $target->{args};
    #             $child_instance = $target->{instance};
    #         } else {
    #             $child_name = $target;
    #             $child_instance = undef;
    #         }
    #         
    #         # Get the child config entry to access its command for selective global merging
    #         my $child_entry = load_config_entry($child_name, $task_by_name, $platform_by_name, $group_by_name, $cfg, $global_defaults);
    #         my $child_command = $child_entry ? ($child_entry->{command} // $child_entry->{build_command} // '') : '';
    #         my $child_merged_args = merge_args($child_command, $child_args, $args, $global_defaults);
    #         
    #         # Add child to worklist for later processing
    #         push @$worklist_ref, [$child_name, $child_merged_args, $canonical_key, $node, 'child', $node_global_defaults, $child_instance];
    #     }
    # }
    
    # Dependencies and notifications are processed by build_graph_with_worklist, not here
    # This function only gets or creates nodes and adds new nodes to worklist
    
    return $node;
}

# --- Helper function to find existing dependency nodes ---
# WHAT: Finds existing nodes that match the given name and arguments
# HOW: Searches through registry nodes and compares name and args
# WHY: Enables reuse of existing nodes instead of creating duplicates
sub find_existing_dependency_node {
    my ($name, $args, $registry) = @_;
    
    for my $node_key (keys %{ $registry->all_nodes }) {
        my $node = $registry->get_node_by_key($node_key);
        next unless $node;
        
        # Check if name matches
        next unless $node->name eq $name;
        
        # Check if args match (simplified comparison)
        my $node_args = $node->get_args;
        my $args_match = 1;
        
        if ($args && ref($args) eq 'HASH' && %$args) {
            if (!$node_args || ref($node_args) ne 'HASH') {
                $args_match = 0;
            } else {
                # Compare only the keys that exist in both
                for my $key (keys %$args) {
                    if (!exists $node_args->{$key} || $node_args->{$key} ne $args->{$key}) {
                        $args_match = 0;
                        last;
                    }
                }
            }
        } elsif ($node_args && ref($node_args) eq 'HASH' && %$node_args) {
            # We have no args but node has args
            $args_match = 0;
        }
        
        if ($args_match) {
            return $node;
        }
    }
    
    return undef;
}

# --- Helper function to add node relationships to worklist ---
# --- Add node relationships to worklist for later processing ---
# WHAT: Adds children, dependencies, and notifications to the worklist for worklist-driven graph expansion
# HOW: Processes targets, dependencies, and notifications, merges arguments, adds entries to worklist with relationship types
# WHY: Enables worklist-driven approach to avoid recursive calls while building the complete dependency graph
# INTERNAL: This is an internal function used by the build system, not intended for direct use
# DEPRECATED: This function is no longer used and is slated for removal.
# sub add_node_relationships_to_worklist {
#     my ($node, $entry, $args, $key, $node_global_defaults, $global_defaults, $worklist_ref, $context_instances) = @_;
#     $context_instances ||= {};
#     
#     # Enqueue children, dependencies, notifies
#     if ($node->is_group && $entry->{targets} && ref($entry->{targets}) eq 'ARRAY') {
#         for my $target (@{ $entry->{targets} }) {
#             my ($child_name, $child_args, $child_instance);
#             if (ref($target) eq 'HASH') {
#                 $child_name = $target->{name};
#                 $child_args = $target->{args};
#                 $child_instance = $target->{instance};
#             } else {
#                 $child_name = $target;
#                 $child_instance = undef;
#             }
#             
#             my $child_merged_args = merge_args($args, $child_args);
#             
#             # Add child to worklist for later processing
#             push @$worklist_ref, [$child_name, $child_merged_args, $key, $node, 'child', $node_global_defaults, $child_instance];
#         }
#     }
#     
#     # Dependencies and notifications are processed by build_graph_with_worklist, not here
#     # This function only gets or creates nodes and adds new nodes to worklist
# }

# --- Propagate Parent Blockers to Children ---
# WHAT: Propagates a parent node's current blockers down to its child/dependency nodes
# HOW: Called when a parent creates a child, passes all current parent blockers to the child
# WHY: Ensures children inherit parent blockers for proper execution ordering
# INTERNAL: This is an internal function used by the build system, not intended for direct use
sub propagate_parent_blockers_to_children {
    my ($parent_node, $child_node, $registry) = @_;
    return unless $parent_node && $child_node;
    
    log_debug("propagate_parent_blockers_to_children: parent=" . $parent_node->name . " child=" . $child_node->name);
    
    # Get all current blockers of the parent
    my @parent_blockers = $parent_node->get_blockers();
    log_debug("Parent " . $parent_node->name . " has " . scalar(@parent_blockers) . " blockers: " . join(", ", @parent_blockers));
    
    # Propagate each blocker to the child
    for my $blocker_key (@parent_blockers) {
        # Find the blocker node in the registry
        if ($registry && $registry->can('get_node_by_key')) {
            my $blocker_node = $registry->get_node_by_key($blocker_key);
            if ($blocker_node) {
                log_debug("Adding blocker " . $blocker_node->name . " to child " . $child_node->name);
                $child_node->add_blocker($blocker_node);
            } else {
                log_debug("Could not find blocker node with key: $blocker_key");
            }
        }
    }
    
    # Also propagate blockers from the parent's dependencies
    # This ensures children inherit blockers from dependencies that the parent waits for
    if ($parent_node->can('dependencies')) {
        my @parent_deps = @{ $parent_node->dependencies || [] };
        for my $dep (@parent_deps) {
            if (ref($dep) && $dep->can('get_blockers')) {
                my @dep_blockers = $dep->get_blockers();
                for my $dep_blocker_key (@dep_blockers) {
                    if ($registry && $registry->can('get_node_by_key')) {
                        my $dep_blocker_node = $registry->get_node_by_key($dep_blocker_key);
                        if ($dep_blocker_node) {
                            log_debug("Adding dependency blocker " . $dep_blocker_node->name . " to child " . $child_node->name);
                            $child_node->add_blocker($dep_blocker_node);
                        }
                    }
                }
                
                # Don't add the dependency itself as a blocker to the child
                # This would create circular dependencies
                # The dependency relationship already ensures proper ordering
            }
        }
    }
    
    # Show final state
    my @child_blockers = $child_node->get_blockers();
    log_debug("Child " . $child_node->name . " now has " . scalar(@child_blockers) . " blockers: " . join(", ", @child_blockers));
}

# --- Process a single node relationship immediately with cycle detection ---
# WHAT: Establishes a single relationship between two nodes with cycle detection and notification setup
# HOW: Checks for cycles, establishes appropriate relationship type, sets up notification-based parent-child relationships
# WHY: Provides immediate relationship processing with safety checks and proper notification configuration
# INTERNAL: This is an internal function used by get_or_create_node, not intended for direct use
sub process_node_relationships_immediately {
    my ($source_node, $target_node, $relationship_type, $registry) = @_;
    
    log_debug("process_node_relationships_immediately: $relationship_type from " . $source_node->name . " to " . $target_node->name);
    
    # Debug: Check if source and target are the same
    my $source_key = $source_node->key;
    my $target_key = $target_node->key;
    
    if (defined($source_key) && defined($target_key) && $source_key eq $target_key) {
        log_debug("WARNING: Same node key detected: " . $source_key);
        log_debug("Source node: " . $source_node->name . " (" . $source_key . ")");
        log_debug("Target node: " . $target_node->name . " (" . $target_key . ")");
        # Don't create self-dependencies
        return;
    }
    
    # Helper function to check if a node is a descendant of another node
    my $is_descendant;
    $is_descendant = sub {
        my ($descendant, $ancestor) = @_;
        return 0 unless $descendant && $ancestor;
        
        # Check immediate parents
        my @parents = @{ $descendant->parents || [] };
        for my $parent (@parents) {
            if (ref($parent) && $parent->key eq $ancestor->key) {
                return 1; # Found immediate parent match
            }
            # Recursively check if any parent is a descendant of the ancestor
            if ($is_descendant->($parent, $ancestor)) {
                return 1;
            }
        }
        return 0;
    };
    
    if ($relationship_type eq 'dependency') {
        # Use Union-Find cycle detection if registry is available
        if ($registry && $registry->can('would_create_cycle')) {
            if ($registry->would_create_cycle($source_node, $target_node)) {
                # Cycle detected - find the actual cycle path for better error reporting
                my $cycle_path = $registry->_find_cycle_path($source_node, $target_node);
                die "Cycle detected: " . join(" -> ", @$cycle_path);
            }
            # Add dependency using registry's method
            $registry->add_dependency($source_node, $target_node);
        } else {
            # Fallback to old cycle detection method
            if ($source_node->would_create_cycle($target_node, {})) {
                die "Cycle detected: Adding dependency from '" . $source_node->name . "' to '" . $target_node->name . "' would create a circular dependency";
            }
            $source_node->add_dependency($target_node);
        }
        
        # Note: Dependency relationships do NOT create parent-child relationships
        # Parent-child relationships are only created for 'child' relationship types
        # This prevents circular dependencies between dependencies and parent-child relationships
        
        # Determine if this is an internal or external dependency
        # Internal: target is a descendant of source (non-blocking for structural readiness)
        # External: target is not a descendant of source (blocking for structural readiness)
        my $is_internal = 0;
        
        # Check if target is a descendant of source (making it an internal dependency)
        $is_internal = $is_descendant->($target_node, $source_node);
        
        # Debug output for dependency separation
        if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
            log_debug("Dependency separation check: " . $source_node->name . " -> " . $target_node->name);
            log_debug("  Target is descendant of source: " . ($is_internal ? "YES (INTERNAL)" : "NO (EXTERNAL)"));
        }
        
        # If this is an external dependency, move it to external_dependencies
        if (!$is_internal) {
            # Remove from internal dependencies
            my @internal_deps = @{ $source_node->get_internal_dependencies() };
            @internal_deps = grep { ref($_) && $_->key ne $target_node->key } @internal_deps;
            $source_node->{dependencies} = \@internal_deps;
            
            # Add to external dependencies
            $source_node->add_external_dependency($target_node);
            
            if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
                log_debug("  Moved dependency to external_dependencies for " . $source_node->name);
            }
        } else {
            if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
                log_debug("  Kept dependency as internal for " . $source_node->name);
            }
        }
        
        # Propagate parent blockers to dependency
        propagate_parent_blockers_to_children($source_node, $target_node, $registry);
        
    } elsif ($relationship_type eq 'notify') {
        # For notifications, the target depends on the source
        if ($registry && $registry->can('would_create_cycle')) {
            if ($registry->would_create_cycle($target_node, $source_node)) {
                # Cycle detected - find the actual cycle path for better error reporting
                my $cycle_path = $registry->_find_cycle_path($target_node, $source_node);
                die "Cycle detected: " . join(" -> ", @$cycle_path);
            }
            # Add dependency using registry's method
            $registry->add_dependency($target_node, $source_node);
        } else {
            # Fallback to old cycle detection method
            if ($target_node->would_create_cycle($source_node, {})) {
                die "Cycle detected: Adding notification from '" . $source_node->name . "' to '" . $target_node->name . "' would create a circular dependency";
            }
            $target_node->add_dependency($source_node);
        }
        # Store the notification relationship for display purposes
        $source_node->add_notify($target_node);
        
        # Determine if this is an internal or external dependency
        # Internal: target is a descendant of source (non-blocking for structural readiness)
        # External: target is not a descendant of source (blocking for structural readiness)
        my $is_internal = 0;
        
        # Check if target is a descendant of source (making it an internal dependency)
        $is_internal = $is_descendant->($target_node, $source_node);
        
        # Debug output for dependency separation
        if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
            log_debug("Notify dependency separation check: " . $source_node->name . " -> " . $target_node->name);
            log_debug("  Target is descendant of source: " . ($is_internal ? "YES (INTERNAL)" : "NO (EXTERNAL)"));
        }
        
        # If this is an external dependency, move it to external_dependencies
        if (!$is_internal) {
            # Remove from internal dependencies
            my @internal_deps = @{ $target_node->get_internal_dependencies() };
            @internal_deps = grep { ref($_) && $_->key ne $source_node->key } @internal_deps;
            $target_node->{dependencies} = \@internal_deps;
            
            # Add to external dependencies
            $target_node->add_external_dependency($source_node);
            
            if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
                log_debug("  Moved dependency to external_dependencies for " . $target_node->name);
            }
        } else {
            if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
                log_debug("  Kept dependency as internal for " . $target_node->name);
            }
        }
        
        # Propagate parent blockers to notification target
        propagate_parent_blockers_to_children($source_node, $target_node, $registry);
        
    } elsif ($relationship_type eq 'child') {
        $source_node->add_child($target_node);
        # Set the parent group for the child
        $target_node->set_parent_group($source_node);
        # Add source node as a parent of target node (multiple parents approach)
        $target_node->add_parent($source_node);
        # COMMENTED OUT: Child should not automatically notify parent on success
        # This creates circular dependencies: all -> mac -> all
        # Parent-child relationships are structural, not execution dependencies
        # $target_node->add_notify_on_success({ name => $source_node->name, args => $source_node->get_args });
        # Note: Groups do NOT depend on their children
        # Groups can execute their children at any time
        # The parent-child relationship is for coordination, not dependencies
        # (Removed legacy implicit child-to-parent notification logic)
        
        # Propagate parent blockers to child
        propagate_parent_blockers_to_children($source_node, $target_node, $registry);
        
    } elsif ($relationship_type eq 'notify_on_success') {
        $source_node->add_notify_on_success($target_node);
        
        # NOTE: Conditional notifications now use the new array-based system
        # No need for bidirectional setup or static dependencies
        
        # Propagate parent blockers to conditional notification target
        propagate_parent_blockers_to_children($source_node, $target_node, $registry);
        
    } elsif ($relationship_type eq 'notify_on_failure') {
        $source_node->add_notify_on_failure($target_node);
        
        # COMMENTED OUT: Failure notifications should not create dependencies
        # When a child notifies its parent group on failure, the parent should not depend on the child
        # Failure notifications are for coordination only, not for execution dependencies
        # if ($registry && $registry->can('would_create_cycle')) {
        #     if ($registry->would_create_cycle($target_node->key, $source_node->key)) {
        #         my $cycle_path = $registry->_find_cycle_path($target_node, $source_node);
        #         die "Cycle detected: " . join(" -> ", @$cycle_path);
        #     }
        #     $registry->add_dependency($target_node, $source_node);
        # } else {
        #     $target_node->add_dependency($source_node);
        # }
        
        # Propagate parent blockers to conditional notification target
        propagate_parent_blockers_to_children($source_node, $target_node, $registry);
    }
}

# --- Format node for display with color coding ---
# WHAT: Formats a node for display with color coding based on type and argument inclusion
# HOW: Extracts name, type, and args, applies color coding, includes relevant arguments in display
# WHY: Provides consistent, visually appealing node representation for debugging and user output
# PUBLIC: This function is part of the public API and can be used by build scripts for display
sub format_node {
    my ($node, $style) = @_;
    $style ||= 'default';
    my ($name, $type, $args, $description);
    if (ref($node) && $node->can('name')) {
        $name = $node->name;
        $type = $node->can('type') ? $node->type : 'unknown';
        $args = $node->can('get_args') ? $node->get_args : {};
        $description = $node->can('description') ? $node->description : undef;
    } else {
        # For hash references, use safe access with defaults
        $name = defined $node->{name} && $node->{name} ne '' ? $node->{name} : '<unnamed>';
        $type = defined $node->{type} && $node->{type} ne '' ? $node->{type} : 'unknown';
        $args = $node->{args} || {};
        $description = $node->{description} || undef;
    }
    if ($style eq 'compact') {
        return $name;
    }
    my $type_color = (defined($type) && $type eq 'task') ? 'blue' :
                     (defined($type) && $type eq 'platform') ? 'green' :
                     (defined($type) && $type eq 'group') ? 'yellow' :
                     'white';
    my $s = Term::ANSIColor::colored($name, $type_color) . " (" . (defined($type) ? $type : 'unknown') . ")";
    if ($args && %$args) {
        my @arg_keys = grep {
            defined $args->{$_} && $args->{$_} ne '' && ref($args->{$_}) eq ''
        } sort keys %$args;
        if (@arg_keys) {
            $s .= " [" . join(", ", map { "$_=$args->{$_}" } @arg_keys) . "]";
        }
    }
    if ($description) {
        $s .= " - $description";
    }
    return $s;
}

=head1 DESIGN NOTE

All BuildNode field access outside the BuildNode class must use accessors/methods (e.g., $node->name, $node->get_args). Treat BuildNode fields as private. Only utility code that must support both BuildNode and hashref may use hash access, and must prefer accessors when available.

=cut

=head1 DESCRIPTION

traverse_nodes($node, $callback, $seen):
  Recursively visits each node (dependencies and children), calling $callback->($node) for each, skipping already-seen nodes.
=cut

# --- DEPRECATED: Node traversal function ---
# WHAT: Recursively visits each node (dependencies and children), calling callback for each
# HOW: Delegates to BuildNode->traverse method with deprecation warning
# WHY: Maintains backward compatibility while encouraging use of the preferred BuildNode method
# DEPRECATED: Use BuildNode->traverse instead of this function
sub traverse_nodes {
    my ($node, $callback, $seen) = @_;
    warn "[DEPRECATED] Use BuildNode->traverse instead of traverse_nodes";
    $node->traverse($callback, $seen);
}

=head2 traverse_nodes($node, $callback, $seen)

DEPRECATED: Use $node->traverse instead. This function now simply calls $node->traverse for backward compatibility.

=cut

# --- Expand command arguments in command strings ---
# WHAT: Replaces variable placeholders in command strings with actual argument values
# HOW: Expands ${key} patterns with args hash values, expands $argN patterns with positional arguments
# WHY: Enables dynamic command generation with variable substitution for flexible build commands
# PUBLIC: This function is part of the public API and can be used by build scripts
sub expand_command_args {
    my ($cmd, $args) = @_;
    $args = {} unless ref($args) eq 'HASH';
    $cmd =~ s/\$\{(\w+)\}/
        (exists $args->{$1}) ? $args->{$1} : ''
    /ge;
    for my $i (1..20) {
        $cmd =~ s/\$arg$i/(exists $args->{"arg$i"}) ? $args->{"arg$i"} : ''/ge;
    }
    return $cmd;
}

# --- Get node by canonical key from node map or registry ---
# WHAT: Retrieves a BuildNode object by its canonical key from a node map or registry
# HOW: Accepts either hash reference or registry object, validates node existence and type
# WHY: Provides safe, consistent node lookup with proper error checking and validation
# PUBLIC: This function is part of the public API and can be used by build scripts
sub get_node_by_key {
    my ($key, $node_map) = @_;
    croak "get_node_by_key: node_map must be a hashref or registry with all_nodes method" unless (
        (ref($node_map) eq 'HASH') || (ref($node_map) && $node_map->can('all_nodes'))
    );
    my $map = (ref($node_map) eq 'HASH') ? $node_map : $node_map->all_nodes;
    my $node = $map->{$key};
    
    # Return undef if no node found (don't croak for missing nodes)
    return undef unless $node;
    
    croak "get_node_by_key: value for key $key is not a BuildNode object" if $node && !(ref($node) && $node->can('key'));
    return $node;
}

# --- Enumerate all notifications in the build system ---
# WHAT: Lists all notification relationships between nodes in the build system
# HOW: Iterates through all nodes, processes unconditional and conditional notifications, returns notification arrays
# WHY: Provides comprehensive view of notification relationships for debugging and analysis
# PUBLIC: This function is part of the public API and can be used by build scripts for analysis
sub enumerate_notifications {
    my ($registry) = @_;
    my @results;
    my $all_nodes = $registry->all_nodes;
    
    for my $node (values %$all_nodes) {
        # Debug: log what we're processing
        if ($VERBOSITY_LEVEL >= 3) {
            my $node_type = ref($node) || 'UNDEF';
            my $node_name = 'UNKNOWN';
            eval { $node_name = $node->name if $node->can('name'); };
            log_debug("enumerate_notifications: processing node: $node_type - $node_name");
        }
        
        # Safety check: ensure this is a valid BuildNode object
        unless (ref($node) && blessed($node) && $node->can('name') && $node->can('get_notifies')) {
            if ($VERBOSITY_LEVEL >= 2) {
                log_debug("enumerate_notifications: skipping invalid node: " . (ref($node) || 'UNDEF'));
            }
            next;
        }
        
                                # Get notification lists directly from the node with error handling
                        my (@unconditional, @success, @failure);
                        eval {
                            @unconditional = $node->get_notifies;
                            @success = $node->get_notifies_on_success;
                            @failure = $node->get_notifies_on_failure;
                        };
                        if ($@) {
                            if ($VERBOSITY_LEVEL >= 2) {
                                log_debug("enumerate_notifications: error getting notifications from node: $@");
                            }
                            next;
                        }

                        # Debug: show what we got from the notification methods
                        if ($VERBOSITY_LEVEL >= 3) {
                            my $node_name = $node->name;
                            log_debug("enumerate_notifications: $node_name notifications - unconditional: " . scalar(@unconditional) . ", success: " . scalar(@success) . ", failure: " . scalar(@failure));
                            if (@unconditional) {
                                log_debug("enumerate_notifications: $node_name unconditional types: " . join(", ", map { ref($_) || 'SCALAR' } @unconditional));
                                for my $i (0..$#unconditional) {
                                    my $item = $unconditional[$i];
                                    if (ref($item) eq 'ARRAY') {
                                        log_debug("enumerate_notifications: $node_name unconditional[$i] is ARRAY with " . scalar(@$item) . " items");
                                        for my $j (0..$#$item) {
                                            my $subitem = $item->[$j];
                                            log_debug("enumerate_notifications: $node_name unconditional[$i][$j] = " . (ref($subitem) || $subitem));
                                        }
                                    } else {
                                        log_debug("enumerate_notifications: $node_name unconditional[$i] = " . (ref($item) || $item));
                                    }
                                }
                            }
                            if (@success) {
                                log_debug("enumerate_notifications: $node_name success types: " . join(", ", map { ref($_) || 'SCALAR' } @success));
                                for my $i (0..$#success) {
                                    my $item = $success[$i];
                                    if (ref($item) eq 'ARRAY') {
                                        log_debug("enumerate_notifications: $node_name success[$i] is ARRAY with " . scalar(@$item) . " items");
                                        for my $j (0..$#$item) {
                                            my $subitem = $item->[$j];
                                            log_debug("enumerate_notifications: $node_name success[$i][$j] = " . (ref($subitem) || $subitem));
                                        }
                                    } else {
                                        log_debug("enumerate_notifications: $node_name success[$i] = " . (ref($item) || $item));
                                    }
                                }
                            }
                            if (@failure) {
                                log_debug("enumerate_notifications: $node_name failure types: " . join(", ", map { ref($_) || 'SCALAR' } @failure));
                                for my $i (0..$#failure) {
                                    my $item = $failure[$i];
                                    if (ref($item) eq 'ARRAY') {
                                        log_debug("enumerate_notifications: $node_name failure[$i] is ARRAY with " . scalar(@$item) . " items");
                                        for my $j (0..$#$item) {
                                            my $subitem = $item->[$j];
                                            log_debug("enumerate_notifications: $node_name failure[$i][$j] = " . (ref($subitem) || $subitem));
                                        }
                                    } else {
                                        log_debug("enumerate_notifications: $node_name failure[$i] = " . (ref($item) || $item));
                                    }
                                }
                            }
                        }

                        # Filter out invalid notification targets but keep valid ones
                        # Handle nested array structure: each notification array contains arrays of BuildNode objects
                        my @valid_unconditional = ();
                        for my $item (@unconditional) {
                            if (ref($item) eq 'ARRAY') {
                                # Flatten nested array and filter valid BuildNode objects
                                my @valid_items = grep { ref($_) && blessed($_) && $_->can('name') } @$item;
                                push @valid_unconditional, @valid_items;
                            } elsif (ref($item) && blessed($item) && $item->can('name')) {
                                push @valid_unconditional, $item;
                            }
                        }
                        
                        my @valid_success = ();
                        for my $item (@success) {
                            if (ref($item) eq 'ARRAY') {
                                # Flatten nested array and filter valid BuildNode objects
                                my @valid_items = grep { ref($_) && blessed($_) && $_->can('name') } @$item;
                                push @valid_success, @valid_items;
                            } elsif (ref($item) && blessed($item) && $item->can('name')) {
                                push @valid_success, $item;
                            }
                        }
                        
                        my @valid_failure = ();
                        for my $item (@failure) {
                            if (ref($item) eq 'ARRAY') {
                                # Flatten nested array and filter valid BuildNode objects
                                my @valid_items = grep { ref($_) && blessed($_) && $_->can('name') } @$item;
                                push @valid_failure, @valid_items;
                            } elsif (ref($item) && blessed($item) && $item->can('name')) {
                                push @valid_failure, $item;
                            }
                        }
                        
                        # Debug: show filtering results
                        if ($VERBOSITY_LEVEL >= 3) {
                            my $node_name = $node->name;
                            log_debug("enumerate_notifications: $node_name valid notifications - unconditional: " . scalar(@valid_unconditional) . ", success: " . scalar(@valid_success) . ", failure: " . scalar(@valid_failure));
                        }
                        
                        # Only include nodes that actually have valid notifications
                        if (@valid_unconditional || @valid_success || @valid_failure) {
        push @results, [
            $node, 
                                \@valid_unconditional, 
                                \@valid_success, 
                                \@valid_failure
                            ];
                        }
    }
    return @results;
}

=head2 enumerate_notifications($registry, %opts)

Yields (returns a list of) [$node, \@notified_nodes] for each node in the registry that notifies others. By default, returns BuildNode objects; pass keys => 1 to return canonical keys instead.

=cut

# --- Helper: Check if a dependency group is empty ---
# WHAT: Determines if a dependency group has no actual dependency children
# HOW: Checks if the node is a dependency group and has no children
# WHY: Allows filtering out empty dependency groups from display
# INTERNAL: This is an internal utility function
sub is_empty_dependency_group {
    my ($node) = @_;
    return 0 unless $node && ref($node) && $node->can('is_dependency_group');
    return 0 unless $node->is_dependency_group;
    # An empty dependency group has no children
    my $children = $node->can('children') ? $node->children : [];
    return scalar(@$children) == 0;
}

# --- Unified Output Utility ---
# print_node_tree($root, $registry, %opts): prints tree, build order, notifications as requested
sub print_node_tree {
    my ($root, $registry, %opts) = @_;
    $opts{tree} //= 1;
    $opts{build_order} //= 0;
    $opts{notifications} //= 0;
    $opts{legend} //= 0;
    my $all_nodes = $registry->all_nodes;
    my %seen;
    my $print_tree;
    $print_tree = sub {
        my ($node, $prefix, $is_last, $parent_is_parallel) = @_;
        
        # Safety check for undefined nodes
        unless (defined $node && ref($node) && $node->can('key')) {
            log_debug("print_node_tree: encountered undefined or invalid node");
            return;
        }
        
        my $key = $node->key;  # Use node key directly for display/tracking purposes
        return if $seen{$key}++;
        # Filter out empty dependency groups from display
        return if is_empty_dependency_group($node);
        my $is_group = $node->is_group;
        my $is_parallel = $is_group && ($node->continue_on_error || $node->parallel);
        my $is_sequential = $is_group && !$is_parallel;
        my $type_color = $is_parallel ? 'cyan' : $is_sequential ? 'yellow' : $node->is_task ? 'blue' : $node->is_platform ? 'green' : 'white';
        my $label = format_node($node, 'default');
        $label = Term::ANSIColor::colored($label, $type_color);
        $label = '⧉ ' . $label . ' (parallel)' if $is_parallel;
        $label .= ' (sequential)' if $is_sequential;
        $label = Term::ANSIColor::colored($label, 'bold') if $opts{default_target} && $node->name eq $opts{default_target};
        # Always show dependencies and notifies inline (using accessors)
        my $extra = '';
        my $deps = $node->can('dependencies') ? $node->dependencies : [];
        if ($deps && @$deps) {
            my @dep_names = map {
                ref($_) && $_->can('name') ? $_->name : (ref($_) eq 'HASH' ? $_->{name} : $_)
            } @$deps;
            $extra .= Term::ANSIColor::colored(' depends on: ', 'bright_black') . join(', ', @dep_names) if @dep_names;
        }
        my $notifies = $node->can('notifies') ? $node->notifies : [];
        if ($notifies && @$notifies) {
            my @notify_names = map {
                ref($_) && $_->can('name') ? $_->name : (ref($_) eq 'HASH' ? $_->{name} : $_)
            } @$notifies;
            $extra .= Term::ANSIColor::colored(' notifies: ', 'bright_black') . join(', ', @notify_names) if @notify_names;
        }
        
        # Add conditional notifications to inline display
        my $notifies_on_success = $node->can('notifies_on_success') ? $node->notifies_on_success : [];
        if ($notifies_on_success && @$notifies_on_success) {
            my @notify_names = map {
                ref($_) && $_->can('name') ? $_->name : (ref($_) eq 'HASH' ? $_->{name} : $_)
            } @$notifies_on_success;
            $extra .= Term::ANSIColor::colored(' notifies on success: ', 'bright_black') . join(', ', @notify_names) if @notify_names;
            # Debug output
            if ($VERBOSITY_LEVEL >= 3) {
                log_debug("print_node_tree: $node->name has " . scalar(@$notifies_on_success) . " success notifications");
            }
        }
        
        my $notifies_on_failure = $node->can('notifies_on_failure') ? $node->notifies_on_failure : [];
        if ($notifies_on_failure && @$notifies_on_failure) {
            my @notify_names = map {
                ref($_) && $_->can('name') ? $_->name : (ref($_) eq 'HASH' ? $_->{name} : $_)
            } @$notifies_on_failure;
            $extra .= Term::ANSIColor::colored(' notifies on failure: ', 'bright_black') . join(', ', @notify_names) if @notify_names;
            # Debug output
            if ($VERBOSITY_LEVEL >= 3) {
                log_debug("print_node_tree: $node->name has " . scalar(@$notifies_on_failure) . " failure notifications");
            }
        }
        
        $label .= $extra;
        # Tree lines
        my $branch = '';
        if ($parent_is_parallel) {
            $branch = $is_last ? '└─ ' : '├─ ';
        }
        print $prefix . $branch . $label . "\n" if $opts{tree};
        # Print notifications separately if requested
        if ($opts{notifications}) {
            # Unconditional notifications
            if ($node->can('get_notifies') && @{ $node->get_notifies }) {
            my @notify_names = map {
                ref($_) && $_->can('name') ? $_->name : (ref($_) eq 'HASH' ? $_->{name} : $_)
            } @{ $node->get_notifies };
            print $prefix . Term::ANSIColor::colored("  notifies: ", 'bright_black') . join(", ", @notify_names) . "\n" if @notify_names;
            }
            
            # Conditional success notifications
            if ($node->can('get_notifies_on_success') && @{ $node->get_notifies_on_success }) {
                my @notify_names = map {
                    ref($_) && $_->can('name') ? $_->name : (ref($_) eq 'HASH' ? $_->{name} : $_)
                } @{ $node->get_notifies_on_success };
                print $prefix . Term::ANSIColor::colored("  notifies on success: ", 'bright_black') . join(", ", @notify_names) . "\n" if @notify_names;
            }
            
            # Conditional failure notifications
            if ($node->can('get_notifies_on_failure') && @{ $node->get_notifies_on_failure }) {
                my @notify_names = map {
                    ref($_) && $_->can('name') ? $_->name : (ref($_) eq 'HASH' ? $_->{name} : $_)
                } @{ $node->get_notifies_on_failure };
                print $prefix . Term::ANSIColor::colored("  notifies on failure: ", 'bright_black') . join(", ", @notify_names) . "\n" if @notify_names;
            }
        }
        my $child_prefix = $prefix;
        if ($parent_is_parallel) {
            $child_prefix .= $is_last ? '    ' : '│   ';
        } else {
            $child_prefix .= '    ';
        }
        unless ($node->is_leaf) {
            # Filter out empty dependency groups before iterating to properly calculate $is_last
            my @filtered_children = grep { !is_empty_dependency_group($_) } @{ $node->children };
            my $n = scalar(@filtered_children);
            for (my $i = 0; $i < $n; $i++) {
                my $child = $filtered_children[$i];
                $print_tree->($child, $child_prefix, $i == $n - 1, $is_parallel);
            }
        }
    };
    # Always display dependencies and notifies, regardless of options
    $print_tree->($root, '', 1, 0);
    if ($opts{build_order}) {
        print Term::ANSIColor::colored("\nBuild Order (true execution order):\n", 'magenta');
        print_build_order_legend() if $opts{legend};
        print_final_build_order($root, '', 1, 0, $opts{default_target}, $all_nodes);
    }
}

# --- Display nodes in build order with notifications ---
sub print_build_order_with_notifications {
    my ($root, $all_nodes, $build_order, $opts) = @_;
    $opts ||= {};
    my $show_notifications = $opts->{show_notifications} // 0;
    
    print "Build Order with Notifications:\n";
    for my $pair (@$build_order) {
        my ($node, $invocation_id) = @$pair;
        my $label = format_node($node, 'default');
        my @dep_lines;
        
        # Notifications using helper methods
        if ($show_notifications) {
            # Unconditional notifications
            if ($node->can('get_notifies') && @{ $node->get_notifies }) {
                for my $notify (@{ $node->get_notifies }) {
                    my $notify_label = BuildNode::get_notification_target_name($notify);
                    push @dep_lines, "  ├─[notify] notifies: $notify_label";
                }
            }
            
            # Conditional success notifications
            if ($node->can('get_notifies_on_success') && @{ $node->get_notifies_on_success }) {
                for my $notify (@{ $node->get_notifies_on_success }) {
                    my $notify_label = BuildNode::get_notification_target_name($notify);
                    push @dep_lines, "  ├─[notify_on_success] notifies on success: $notify_label";
                }
            }
            
            # Conditional failure notifications
            if ($node->can('get_notifies_on_failure') && @{ $node->get_notifies_on_failure }) {
                for my $notify (@{ $node->get_notifies_on_failure }) {
                    my $notify_label = BuildNode::get_notification_target_name($notify);
                    push @dep_lines, "  ├─[notify_on_failure] notifies on failure: $notify_label";
                }
            }
        }
        
        print "$label\n";
        print "$_\n" for @dep_lines;
    }
}

# --- Enhanced Tree Display with Explicit/Implicit Dependencies and Notifies ---
sub print_enhanced_tree {
    my ($root, $all_nodes, $opts) = @_;
    $opts ||= {};
    my $show_notifications = $opts->{show_notifications} // 0;
    
    # Get the registry object to access build order
    if ($VERBOSITY_LEVEL >= 3) {
        log_debug("print_enhanced_tree: all_nodes type: " . (ref($all_nodes) || 'SCALAR'));
        if (ref($all_nodes)) {
            log_debug("print_enhanced_tree: all_nodes can get_build_order: " . (UNIVERSAL::can($all_nodes, 'get_build_order') ? "yes" : "no"));
        }
    }
    
    my $registry;
    if (ref($all_nodes) && UNIVERSAL::can($all_nodes, 'has_node')) {
        $registry = $all_nodes;
    } else {
        # If we only have the hash, we can't get build order - fall back to tree traversal
        log_warn("print_enhanced_tree: No registry available, falling back to tree traversal");
        _print_tree_traversal($root, $all_nodes, $opts);
        return;
    }
    
    # Use tree traversal to show hierarchical structure with dependencies
    _print_tree_traversal($root, $registry->all_nodes, $opts);
}

# --- Fallback tree traversal method ---
sub _print_tree_traversal {
    my ($root, $all_nodes, $opts) = @_;
    $opts ||= {};
    my $show_notifications = $opts->{show_notifications} // 0;
    my %seen;
    
    my $print_tree;
    $print_tree = sub {
        my ($node, $prefix, $parent) = @_;
        unless (ref($node) && $node->can('name')) {
            log_warn("print_enhanced_tree: Encountered non-BuildNode in tree. Type: " . (ref($node) || 'SCALAR') . ", Value: $node. Skipping.");
            return;
        }
        my $key = get_key_from_node($node);
        return if $seen{$key}++;
        # Filter out empty dependency groups from display
        return if is_empty_dependency_group($node);
        
        my $label = format_node($node, 'default');
        my @dep_lines;
        
        # Explicit dependencies
        if ($node->can('dependencies') && $node->dependencies && @{ $node->dependencies }) {
            for my $dep (@{ $node->dependencies }) {
                unless (ref($dep) && UNIVERSAL::can($dep, 'name')) {
                    log_warn("print_enhanced_tree: Node '" . $node->name . "' has non-BuildNode dependency. Type: " . (ref($dep) || 'SCALAR') . ", Value: $dep. Skipping.");
                    next;
                }
                my $dep_label = format_node($dep, 'compact');
                push @dep_lines, $prefix . "  ├─[explicit] depends on: $dep_label";
            }
        }
        
        # Implicit dependencies (sequential group)
        if ($parent && $parent->can('is_group') && $parent->is_group && !($parent->continue_on_error || $parent->parallel)) {
            my $children = $parent->children;
            for (my $i = 1; $i < @$children; $i++) {
                if ($children->[$i] == $node) {
                    my $prev = $children->[$i-1];
                    unless (ref($prev) && UNIVERSAL::can($prev, 'name')) {
                        log_warn("print_enhanced_tree: Sequential group has non-BuildNode child. Type: " . (ref($prev) || 'SCALAR') . ", Value: $prev. Skipping.");
                        next;
                    }
                    my $prev_label = format_node($prev, 'compact');
                    push @dep_lines, $prefix . "  ├─[implicit] after: $prev_label";
                }
            }
        }
        
        # Notifications using helper methods
        if ($show_notifications) {
            # Unconditional notifications
            if ($node->can('get_notifies') && @{ $node->get_notifies }) {
                for my $notify (@{ $node->get_notifies }) {
                    my $notify_label = BuildNode::get_notification_target_name($notify);
                push @dep_lines, $prefix . "  ├─[notify] notifies: $notify_label";
            }
        }
            
            # Conditional success notifications
            if ($node->can('get_notifies_on_success') && @{ $node->get_notifies_on_success }) {
                for my $notify (@{ $node->get_notifies_on_success }) {
                    my $notify_label = BuildNode::get_notification_target_name($notify);
                    push @dep_lines, $prefix . "  ├─[notify_on_success] notifies on success: $notify_label";
                }
            }
            
            # Conditional failure notifications
            if ($node->can('get_notifies_on_failure') && @{ $node->get_notifies_on_failure }) {
                for my $notify (@{ $node->get_notifies_on_failure }) {
                    my $notify_label = BuildNode::get_notification_target_name($notify);
                    push @dep_lines, $prefix . "  ├─[notify_on_failure] notifies on failure: $notify_label";
                }
            }
        }
        
        print $prefix . $label . "\n";
        print "$_\n" for @dep_lines;
        
        unless ($node->is_leaf) {
            # Filter out empty dependency groups before iterating
            my @filtered_children = grep { 
                ref($_) && UNIVERSAL::can($_, 'name') && !is_empty_dependency_group($_)
            } @{ $node->children };
            for my $child (@filtered_children) {
                        unless (ref($child) && UNIVERSAL::can($child, 'name')) {
            log_warn("print_enhanced_tree: Node '" . $node->name . "' has non-BuildNode child. Type: " . (ref($child) || 'SCALAR') . ", Value: $child. Skipping.");
            next;
        }
                $print_tree->($child, $prefix . "  ", $node);
            }
        }
    };
    $print_tree->($root, '', undef);
}

# --- Unified Summary/Reporting Utility ---
# print_node_summary($root, $status_mgr): prints summary of platforms, tasks, groups, and their statuses/durations if available
sub print_node_summary {
    my ($root, $status_mgr) = @_;
    my (%platforms, %tasks, %groups, %platform_nodes, %task_nodes, %group_nodes);
    $root->traverse(sub {
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
    for my $name (sort keys %platforms) {
        my $node = $platform_nodes{$name};
        my $status = $status_mgr ? ($status_mgr->get_status($node) // $node->status // '') : '';
        my $duration = $status_mgr ? ($status_mgr->get_duration($node) // $node->duration // '') : '';
        printf("  - %-30s %-10s (%ss)\n", format_node($node, 'default'), $status, $duration) if $status_mgr;
        printf("  - %s\n", format_node($node, 'default')) unless $status_mgr;
    }
    print "\nAvailable Tasks:\n";
    for my $name (sort keys %tasks) {
        my $node = $task_nodes{$name};
        my $status = $status_mgr ? ($status_mgr->get_status($node) // $node->status // '') : '';
        my $duration = $status_mgr ? ($status_mgr->get_duration($node) // $node->duration // '') : '';
        printf("  - %-30s %-10s (%ss)\n", format_node($node, 'default'), $status, $duration) if $status_mgr;
        printf("  - %s\n", format_node($node, 'default')) unless $status_mgr;
    }
    print "\nAvailable Build Groups:\n";
    for my $name (sort keys %groups) {
        my $node = $group_nodes{$name};
        printf("  - %s\n", format_node($node, 'default'));
    }
    print "\n";
}

# --- Unified Build Order/Execution Summary Utility ---
# print_node_build_order($root, $registry, \@build_order_pairs, %opts): prints build order and execution summary
sub print_node_build_order {
    my ($root, $registry, $build_order_pairs, %opts) = @_;
    $opts{legend} //= 1;
    $opts{invocation_ids} //= 0;
    my $all_nodes = $registry->all_nodes;
    print Term::ANSIColor::colored("\nBUILD ORDER (true execution order):\n", 'magenta');
    print_build_order_legend() if $opts{legend};
    if ($build_order_pairs && ref($build_order_pairs) eq 'ARRAY' && @$build_order_pairs) {
        printf("%-40s %-10s %-10s %-10s\n", "Target", "Type", "Status", "Duration");
        print "-" x 70 . "\n";
        for my $pair (@$build_order_pairs) {
            my ($node, $invocation_id) = @$pair;
            my $status = $opts{status_mgr} ? $opts{status_mgr}->get_status($node, $invocation_id) // $node->status // '' : $node->status // '';
            my $duration = $opts{status_mgr} ? $opts{status_mgr}->get_duration($node, $invocation_id) // $node->duration // '' : $node->duration // '';
            my $type = $node->type // '';
            my $label = $node->key;
            if ($opts{invocation_ids}) {
                printf("%-40s [id=%d] %-10s %-10s\n", $label, $invocation_id, $status, $duration);
            } else {
                printf("%-40s %-10s %-10s %-10s\n", $label, $type, $status, $duration);
            }
        }
    } else {
        # Fallback: print tree-like build order
        print_final_build_order($root, '', 1, 0, $opts{default_target}, $all_nodes);
    }
    print "\n";
}

# --- Helper function to format node name with instance and argument information ---
sub format_node_name_with_instance {
    my ($node) = @_;
    my $name = $node->name;
    my $key = $node->key;
    my $args = $node->get_args;
    
    # Extract instance information from the canonical key
    if ($key =~ /\|instance=([^|]+)$/) {
        my $instance = $1;
        $name = "$name($instance)";
    }
    
    # Add distinguishing arguments if they exist
    my @distinguishing_args;
    if ($args && ref($args) eq 'HASH') {
        # Show key arguments that help distinguish between instances
        for my $arg (sort keys %$args) {
            my $value = $args->{$arg};
            if (defined $value && $value ne '' && ref($value) eq '') {
                # Skip some common args that don't help distinguish
                next if $arg =~ /^(configs|default_target|project_name)$/;
                push @distinguishing_args, "$arg=$value";
            }
        }
    }
    
    if (@distinguishing_args) {
        return "$name [" . join(", ", @distinguishing_args) . "]";
    }
    
    return $name;
}

# --- Print Parallel-Aware Build Order ---
sub print_parallel_build_order {
    my ($steps, $registry, $tree) = @_;
    print Term::ANSIColor::colored("\nPARALLEL-AWARE BUILD ORDER:\n", 'magenta');
    my $step_num = 1;
    for my $group (@$steps) {
        if (@$group > 1) {
            # Parallel step - show each node on its own line with tree structure
            print "[Step $step_num] # can run in parallel\n";
            for my $i (0..$#$group) {
                my $node = $group->[$i];
                my $is_last = ($i == $#$group);
                my $prefix = $is_last ? "    └─ " : "    ├─ ";
                my $name = format_node_name_with_instance($node);
                print "$prefix$name\n";
                
                # Show notification relationships for each node
                if ($registry && $tree) {
                    my $node_key = $node->can('key') ? $node->key : $node->name;
                    my $registry_node = $registry->get_node_by_key($node_key);
                    if ($registry_node && $registry_node->can('get_notifies')) {
                        my @notifies = @{ $registry_node->get_notifies // [] };
                        if (@notifies) {
                            my @notify_names = map { $_->{name} } @notifies;
                            my $notify_prefix = $is_last ? "        " : "    │   ";
                            print "$notify_prefix└─ notifies: " . join(", ", @notify_names) . "\n";
                        }
                    }
                }
            }
        } else {
            # Sequential step - show single node
            my $node = $group->[0];
            my $name = format_node_name_with_instance($node);
            print "[Step $step_num] $name\n";
            
            # Show notification relationships for the single node
            if ($registry && $tree) {
                my $node_key = $node->can('key') ? $node->key : $node->name;
                my $registry_node = $registry->get_node_by_key($node_key);
                if ($registry_node && $registry_node->can('get_notifies')) {
                    my @notifies = @{ $registry_node->get_notifies // [] };
                    if (@notifies) {
                        my @notify_names = map { $_->{name} } @notifies;
                        print "    └─ notifies: " . join(", ", @notify_names) . "\n";
                    }
                }
            }
        }
        
        $step_num++;
    }
    print "\n";
}

# --- Logging Helpers ---
# --- Logging functions with verbosity control ---
# WHAT: Provides consistent logging functions with color coding and verbosity levels
# HOW: Uses Term::ANSIColor for colored output, respects VERBOSITY_LEVEL for output control
# WHY: Ensures consistent logging format and verbosity control across the build system
# PUBLIC: These functions are part of the public API and can be used by build scripts
sub log_time { localtime->strftime('%Y-%m-%d %H:%M:%S'); }
sub log_info    { print "[INFO]    $_[0]\n" if $VERBOSITY_LEVEL >= 1; }
sub log_success { print Term::ANSIColor::colored("[SUCCESS] $_[0]\n", 'green') if $VERBOSITY_LEVEL >= 1; }
sub log_error   { print STDERR Term::ANSIColor::colored("[ERROR]   $_[0]\n", 'red') if $VERBOSITY_LEVEL >= 0; }
sub log_verbose { print Term::ANSIColor::colored("[VERBOSE] $_[0]\n", 'cyan') if $VERBOSITY_LEVEL >= 2; }
sub log_debug   { print Term::ANSIColor::colored("[DEBUG]   $_[0]\n", 'blue') if $VERBOSITY_LEVEL >= 3; }
sub log_warn    { print STDERR Term::ANSIColor::colored("[WARN]    $_[0]\n", 'yellow') if $VERBOSITY_LEVEL >= 1; }

# --- Build fast-access config lookup tables ---
# WHAT: Creates hash tables for fast lookup of tasks, platforms, and groups by name
# HOW: Iterates through config sections, creates name-indexed hash tables for O(1) lookups
# WHY: Provides efficient name-based lookups during graph construction instead of linear searches
# INTERNAL: This is an internal function used by build_graph_with_worklist, not intended for direct use
sub build_config_lookup_tables {
    my ($cfg) = @_;
    my %task_by_name;
    for my $task (@{ $cfg->{tasks} // [] }) {
        my $name = ref($task) && UNIVERSAL::can($task, 'name') ? $task->name : $task->{name};
        $task_by_name{$name} = $task if $name;
    }
    my %platform_by_name;
    for my $platform (@{ $cfg->{platforms} // [] }) {
        my $name = ref($platform) && UNIVERSAL::can($platform, 'name') ? $platform->name : $platform->{name};
        $platform_by_name{$name} = $platform if $name;
    }
    my %group_by_name = %{ $cfg->{build_groups} // {} };
    return (\%task_by_name, \%platform_by_name, \%group_by_name);
}

# --- Lookup config entry by name across all categories ---
# WHAT: Finds a configuration entry by name across tasks, platforms, and groups
# HOW: Searches task_by_name, platform_by_name, and group_by_name hash tables in order
# WHY: Provides unified lookup interface for all config entry types during graph construction
# INTERNAL: This is an internal function used by load_config_entry, not intended for direct use
sub lookup_config_entry {
    my ($name, $task_by_name, $platform_by_name, $group_by_name) = @_;
    return $task_by_name->{$name} // $platform_by_name->{$name} // $group_by_name->{$name};
}

# --- Unified node creation function ---
# WHAT: Creates BuildNode objects from config entries with proper argument handling
# HOW: Handles both BuildNode objects and hash references, creates nodes with canonical args and keys
# WHY: Provides the single point of node creation to ensure consistency and proper argument handling
# INTERNAL: This is an internal function used by build_and_register_node, not intended for direct use
sub create_node {
    my ($entry, $args, $canonical_key) = @_;
    $args ||= {};
    
    # The args passed here should already be the final merged args (including globals)
    # since the canonical key was computed with the correct args at the higher level
    my %canonical_args = %$args;
    
    # Create the node with only the canonical args (what's actually needed for execution)
    my $node;
    if (ref($entry) && UNIVERSAL::can($entry, 'name')) {
        # It's already a BuildNode object, clone it with new args
        $node = BuildNode->new(
            name           => $entry->name,
            type           => $entry->type,
            command        => $entry->command,
            build_command  => $entry->build_command,
            inputs         => $entry->inputs,
            outputs        => $entry->outputs,
            always_run     => $entry->always_run,
            log_file       => $entry->log_file,
            archive        => $entry->archive,
            continue_on_error => $entry->continue_on_error,
            parallel       => $entry->parallel,
            notifies       => $entry->notifies,
            requires_execution_of => $entry->requires_execution_of,
            args           => \%canonical_args,  # Only canonical args for execution
            canonical_key  => $canonical_key,    # Store the canonical key
        );
    } else {
        # It's a hash reference, construct node with ALL fields from config entry
        my %fields = (
            name           => $entry->{name},
            type           => $entry->{type},
            args           => \%canonical_args,  # Only canonical args for execution
        );
        
        # Copy only flag fields (behavioral configuration) - not structural/relationship fields
        for my $field (qw(always_run continue_on_error parallel args_optional)) {
            if (exists $entry->{$field}) {
                $fields{$field} = $entry->{$field};
            }
        }
        
        # All other fields (command, dependencies, notifies, etc.) are set by relationship processing
        
        $node = BuildNode->new(%fields, canonical_key => $canonical_key);
    }
    
    return $node;
}

# --- Build and register node from config entry and merged args ---
# WHAT: Creates a BuildNode from config entry and registers it in the node registry
# HOW: Creates node using create_node, validates required fields, registers with canonical key
# WHY: Provides the complete node creation and registration process for the build system
# INTERNAL: This is an internal function used by get_or_create_node, not intended for direct use
sub build_and_register_node {
    my ($entry, $merged_args, $registry, $task_by_name, $platform_by_name, $group_by_name, $canonical_key, $dedupe_nodes) = @_;
    return undef unless $entry;
    unless (defined $entry->{name}) {
        my $ref_name = (ref($entry) eq 'HASH' && exists $entry->{ref_name}) ? $entry->{ref_name} : '';
        my $msg = "build_and_register_node: config entry missing 'name', cannot construct node";
        if ($ref_name) {
            $msg .= " (reference: $ref_name)";
        } elsif (defined $entry) {
            if (ref($entry) eq 'HASH') {
                $msg .= " (entry keys: " . join(", ", sort keys %$entry) . ")";
            } else {
                $msg .= " (entry: $entry)";
            }
        } else {
            $msg .= " (entry: undef)";
        }
        log_warn($msg);
        return undef;
    }
    unless (defined $merged_args) {
        log_warn("build_and_register_node: merged_args is undefined for node '$entry->{name}'");
        return undef;
    }
    my $normalized_args = read_args($merged_args);
    
    # Use unified node creation (args should already be the final merged args)
    my $obj = create_node($entry, $normalized_args, $canonical_key);
    unless ($obj) {
        log_warn("build_and_register_node: create_node failed for node '$entry->{name}'");
        return undef;
    }
    
    # Use the canonical key passed from the caller - but only deduplicate when deduplication is enabled
    # Regular tasks should be allowed to exist in multiple parent contexts
    my $existing_node;
    if ($dedupe_nodes) {
        $existing_node = $registry->get_node_by_key($canonical_key);
        if ($existing_node) {
            log_debug("build_and_register_node: returning existing deduplicated node " . $existing_node->name . " with key " . $canonical_key);
            return $existing_node;
        }
    }
    
    # Add the node to the registry (this should be the only instance)
    $registry->add_node($obj);
    
    # Set core execution fields explicitly (structural/relationship fields only)
    # Flag fields (always_run, continue_on_error, parallel, args_optional) are handled in create_node
    if (ref($entry) eq 'HASH') {
        $obj->{command} = $entry->{command} if exists $entry->{command};
        $obj->{build_command} = $entry->{build_command} if exists $entry->{build_command};
        $obj->{inputs} = $entry->{inputs} if exists $entry->{inputs};
        $obj->{outputs} = $entry->{outputs} if exists $entry->{outputs};
        $obj->{log_file} = $entry->{log_file} if exists $entry->{log_file};
        $obj->{archive} = $entry->{archive} if exists $entry->{archive};
        $obj->{requires_execution_of} = $entry->{requires_execution_of} if exists $entry->{requires_execution_of};
    }
    
    # Group flag fields (continue_on_error, parallel) are handled in create_node like all other flag fields
    # No special processing needed for groups - DRY principle
    # Do not process dependencies, notifies, or children here!
    return $obj;
}

# --- Inject implicit dependencies for sequential groups ---
# WHAT: Adds implicit dependencies between children of sequential groups to ensure proper execution order
# HOW: Traverses sequential groups, adds dependencies from each child to the previous one
# WHY: Ensures sequential execution order for children of sequential groups
# INTERNAL: This is an internal function used by the build system, not intended for direct use
sub inject_sequential_group_dependencies {
    my ($root, $registry) = @_;
    $root->traverse(sub {
        my $node = shift;
        return unless $node->is_group;
        
        # Check if this group is parallel
        # Groups are sequential by default unless explicitly set to parallel
        # continue_on_error makes a group parallel (allows children to run in parallel)
        my $is_parallel = 0; # Default to sequential
        if ($node->can('parallel')) {
            $is_parallel = $node->parallel;
        }
        if ($node->can('continue_on_error') && $node->continue_on_error) {
            $is_parallel = 1; # continue_on_error makes the group parallel
        }
        
        # Only process if sequential (not parallel)
        if ($is_parallel) {
            log_debug("Skipping sequential group dependencies for parallel group: " . $node->name);
            return;
        }
        
        my $children = $node->children;
        return unless $children && @$children > 1;
        
        log_debug("Processing sequential group dependencies for: " . $node->name . " with " . scalar(@$children) . " children");
        for (my $i = 1; $i < @$children; $i++) {
            my $prev = $children->[$i-1];
            my $curr = $children->[$i];
            log_debug("Adding sequential dependency: " . $prev->name . " -> " . $curr->name);
            
                    # Use Union-Find cycle detection if registry is available
        if ($registry && $registry->can('would_create_cycle')) {
            if ($registry->would_create_cycle($curr, $prev)) {
                log_debug("Skipping sequential dependency " . $curr->name . " -> " . $prev->name . " (would create cycle)");
                next;
            }
                # Add dependency using registry's method (this creates execution dependency only)
                # curr depends on prev (curr waits for prev to complete)
            $registry->add_dependency($curr, $prev);
        } else {
            # Fallback to old cycle detection method
            if ($curr->would_create_cycle($prev)) {
                log_debug("Skipping sequential dependency " . $curr->name . " -> " . $prev->name . " (would create cycle)");
                next;
            }
                # Only add if not already present
                unless (grep { $_ == $prev } @{ $curr->dependencies }) {
                    # CRITICAL: Use direct field access to avoid creating parent relationships
                    # Sequential dependencies within a group should NOT create parent relationships
                    # curr depends on prev (curr waits for prev to complete)
                    push @{ $curr->{dependencies} }, $prev;
                }
            }
        }
    });
}

# --- Inject implicit dependencies for sequential dependencies ---
# WHAT: Adds implicit dependencies between multiple dependencies of a node to ensure proper execution order
# HOW: Traverses nodes with multiple dependencies, adds dependencies from each dependency to the previous one
# WHY: Ensures sequential execution order for multiple dependencies of the same node
# INTERNAL: This is an internal function used by the build system, not intended for direct use
sub inject_sequential_dependencies_for_dependencies {
    my ($root, $registry) = @_;
    $root->traverse(sub {
        my $node = shift;
        my $deps = $node->dependencies;
        return unless $deps && @$deps > 1;
        log_debug("Processing dependencies for node: " . $node->name . " with " . scalar(@$deps) . " deps");
        for (my $i = 1; $i < @$deps; $i++) {
            my $prev = $deps->[$i-1];
            my $curr = $deps->[$i];
            log_debug("prev: " . (ref($prev) ? ref($prev) . ":" . $prev->name : "string:" . $prev));
            log_debug("curr: " . (ref($curr) ? ref($curr) . ":" . $curr->name : "string:" . $curr));
            # Skip if either dependency is not a BuildNode object
            next unless ref($prev) && UNIVERSAL::can($prev, 'dependencies');
            next unless ref($curr) && UNIVERSAL::can($curr, 'dependencies');
            
            # Use Union-Find cycle detection if registry is available
        if ($registry && $registry->can('would_create_cycle')) {
            if ($registry->would_create_cycle($curr, $prev)) {
                log_debug("Skipping sequential dependency " . $curr->name . " -> " . $prev->name . " (would create cycle)");
                next;
            }
            # Add dependency using registry's method
            $registry->add_dependency($curr, $prev);
        } else {
                # Fallback to old cycle detection method
                if ($curr->would_create_cycle($prev)) {
                    log_debug("Skipping sequential dependency " . $curr->name . " -> " . $prev->name . " (would create cycle)");
                    next;
                }
                # Always add implicit dependency from curr to prev, regardless of type (task or group)
                unless (grep { $_ eq $prev } @{ $curr->dependencies }) {
                    $curr->add_dependency($prev);
                }
            }
        }
    });
}

# --- Build graph using worklist-driven approach ---
# WHAT: Constructs the complete build graph using a worklist to avoid recursive calls
# HOW: Uses worklist to process nodes breadth-first, creates nodes with canonical keys, establishes relationships
# WHY: Provides efficient, non-recursive graph construction that handles complex dependency relationships
# PUBLIC: This is the primary public interface for building the complete dependency graph
sub build_graph_with_worklist {
    my ($root_name, $root_args, $cfg, $global_defaults, $registry) = @_;
    
    # Debug output removed for cleaner logs
    
    require Storable;
    my @worklist;
    my ($task_by_name, $platform_by_name, $group_by_name) = build_config_lookup_tables($cfg);
    
    # Get the root config entry to access its command for selective global merging
    my $root_entry = load_config_entry($root_name, $task_by_name, $platform_by_name, $group_by_name, $cfg, $global_defaults);
    my $root_command = $root_entry ? ($root_entry->{command} // $root_entry->{build_command} // '') : '';
    my $merged_root_args = merge_args($root_command, $root_args, undef, $global_defaults);
    
    # Worklist entries: [node_ref, parent_node, relationship, global_defaults, instance_spec]
    # Create the root node first and add it to worklist
    my $initial_root_node = get_or_create_node($root_name, $merged_root_args, undef, undef, 'root', $global_defaults, $registry, $task_by_name, $platform_by_name, $group_by_name, $cfg, $global_defaults, \@worklist, undef);
    
    # GOCN already added the root node to worklist, no need to add it again
    
    while (@worklist) {
        my ($node_ref, $parent_node, $relationship, $node_global_defaults, $instance_spec) = @{ shift @worklist };
        
        # The worklist contains BuildNode references - process the node directly
        my $node = $node_ref;
        
        # No need to track root key anymore - we'll find the root node by name later
        
        # Process relationships immediately after node creation (in BGW, not in GCN)
        if ($node) {
            # Get the config entry for this node to access relationships
            my $entry = load_config_entry($node->name, $task_by_name, $platform_by_name, $group_by_name, $cfg, $global_defaults);
            
            if ($entry) {
                # Process dependencies: create/find each dependency and immediately establish relationship
                # CRITICAL: ALWAYS create dependency groups for ALL nodes, even if they have no dependencies
                # This ensures consistent coordination logic across all node types
                my @deps = $entry->{dependencies} && ref($entry->{dependencies}) eq 'ARRAY' ? @{ $entry->{dependencies} } : [];
                if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
                    log_debug("Creating dependency group for node: " . $node->name . " with " . scalar(@deps) . " dependencies (node type: " . ($node->type // 'unknown') . ")");
                }
                my $dep_parent = create_dependency_parent($node, \@deps, $global_defaults, $node->args, $node_global_defaults, $registry, $task_by_name, $platform_by_name, $group_by_name, $cfg, \@worklist);
                        # Note: create_dependency_parent already sets up the dependency relationship
                        # No need to call process_node_relationships_immediately here
                
                # Attach child nodes: create/find each child and add to worklist
                if ($entry->{targets} && ref($entry->{targets}) eq 'ARRAY') {
                    my $prior_child_node;  # For sequential children notifications
                    my $child_order = 1;   # Start with order 1
                    
                    for my $target (@{ $entry->{targets} }) {
                        my ($child_name, $child_args, $child_notifies, $child_requires_execution_of, $child_instance, $child_notify_on_success, $child_notify_on_failure);
                        if (ref($target) eq 'HASH') {
                            $child_name = $target->{name};
                            $child_args = $target->{args};
                            $child_notifies = $target->{notifies};
                            $child_requires_execution_of = $target->{requires_execution_of};
                            $child_instance = $target->{instance};
                            $child_notify_on_success = $target->{notify_on_success};
                            $child_notify_on_failure = $target->{notify_on_failure};
                        } else {
                            $child_name = $target;
                            $child_notifies = undef;
                            $child_requires_execution_of = undef;
                            $child_instance = undef;
                            $child_notify_on_success = undef;
                            $child_notify_on_failure = undef;
                        }
                        
                        # Get the child config entry to access its command for selective global merging
                        my $child_entry = load_config_entry($child_name, $task_by_name, $platform_by_name, $group_by_name, $cfg, $global_defaults);
                        
                        # Merge notification fields from target specification with config entry
                        if ($child_entry && ref($child_entry) eq 'HASH') {
                            # Merge notify_on_success if specified in target
                            if ($child_notify_on_success) {
                                if (ref($child_notify_on_success) eq 'ARRAY') {
                                    $child_entry->{notifies_on_success} = $child_notify_on_success;
                                } else {
                                    $child_entry->{notifies_on_success} = [$child_notify_on_success];
                                }
                            }
                            
                            # Merge notify_on_failure if specified in target
                            if ($child_notify_on_failure) {
                                if (ref($child_notify_on_failure) eq 'ARRAY') {
                                    $child_entry->{notifies_on_failure} = $child_notify_on_failure;
                                } else {
                                    $child_entry->{notifies_on_failure} = [$child_notify_on_failure];
                                }
                            }
                            
                            # Merge notifies if specified in target
                            if ($child_notifies) {
                                if (ref($child_notifies) eq 'ARRAY') {
                                    $child_entry->{notifies} = $child_notifies;
                                } else {
                                    $child_entry->{notifies} = [$child_notifies];
                                }
                            }
                            
                            # Merge requires_execution_of if specified in target
                            if ($child_requires_execution_of) {
                                if (ref($child_requires_execution_of) eq 'ARRAY') {
                                    $child_entry->{requires_execution_of} = $child_requires_execution_of;
                                } else {
                                    $child_entry->{requires_execution_of} = [$child_requires_execution_of];
                                }
                            }
                            
                            # Update the lookup table to persist the changes
                            if (exists $task_by_name->{$child_name}) {
                                $task_by_name->{$child_name} = $child_entry;
                            } elsif (exists $platform_by_name->{$child_name}) {
                                $platform_by_name->{$child_name} = $child_entry;
                            } elsif (exists $group_by_name->{$child_name}) {
                                $group_by_name->{$child_name} = $child_entry;
                            }
                        }
                        
                        my $child_command = $child_entry ? ($child_entry->{command} // $child_entry->{build_command} // '') : '';
                        my $child_merged_args = merge_args($child_command, $child_args, $node->args, $global_defaults);
                        
                        # Create/find the child node (single call, no recursion)
                        if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
                            log_debug("Processing child '$child_name' with parent '" . $node->name . "' (child_order: $child_order, parent: " . $node->name . ")");
                        }
                        my $child_node = get_or_create_node($child_name, $child_merged_args, $node->key, $node, 'child', $node_global_defaults, $registry, $task_by_name, $platform_by_name, $group_by_name, $cfg, $global_defaults, \@worklist, $child_instance);
                        
                        if ($child_node) {
                                                    # Special case: if this is a dependency group, set child_order to 0
                        if ($child_node->name =~ /_dependency_group$/) {
                            $child_node->set_child_order(0);
                            # NO increment for dependency groups - they don't count in the sequence
                        } else {
                            # Auto-assign child_order for sequential execution
                            $child_node->set_child_order($child_order);
                            # Increment child_order for next regular child
                            $child_order++;
                        }
                        
                        # Child node is already added to worklist by get_or_create_node
                        
                        # Establish parent->child relationship (this creates the tree structure AND child->parent notification)
                        if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
                            log_debug("Establishing parent-child relationship: " . $node->name . " -> " . $child_node->name);
                            my $parents = $child_node->get_clean_parents();
                            log_debug("Child " . $child_node->name . " has " . scalar(@$parents) . " parents: " . join(", ", map { $_->name } @$parents));
                        }
                        process_node_relationships_immediately($node, $child_node, 'child', $registry);
                        # Register parent as a completion_notify target for the child
                        $child_node->add_completion_notify_target($node);
                        $node->expect_completion_from($child_node);
                            
                            # For sequential children: establish notification from prior child to current child
                            my $parent_is_parallel = 0;
                            my $parent_continue_on_error = 1;  # Default to true for backward compatibility
                            if ($node->can('parallel')) {
                                $parent_is_parallel = $node->parallel;
                            }
                            if ($node->can('continue_on_error')) {
                                $parent_continue_on_error = $node->continue_on_error;
                            }
                            
                            if ($prior_child_node && !$parent_is_parallel) {
                                # Use notify_on_success for sequential children when continue_on_error is false
                                # This ensures dependency failures properly break the execution chain
                                my $relationship_type = $parent_continue_on_error ? 'notify' : 'notify_on_success';
                                process_node_relationships_immediately($prior_child_node, $child_node, $relationship_type, $registry);
                            }
                            
                            $prior_child_node = $child_node;  # Update prior child reference
                        }
                    }
                }
                
                
                # Process notifications: create/find each notification target and immediately establish relationship
                if ($entry->{notifies} && ref($entry->{notifies}) eq 'ARRAY') {
                    my $context = {
                        global_defaults => $global_defaults,
                        args => $node->args,
                        child_merged_args => $node->args,  # For top-level nodes, use args as child_merged_args
                        node_global_defaults => $node_global_defaults,
                        task_by_name => $task_by_name,
                        platform_by_name => $platform_by_name,
                        group_by_name => $group_by_name,
                        cfg => $cfg,
                        worklist => \@worklist
                    };
                    
                    my @processed_notifications = process_notification_relationships($node, $entry->{notifies}, $registry, $context);
                    
                    # Handle sequential notification dependencies
                    for my $i (1..$#processed_notifications) {
                        my $prior_notify_node = $processed_notifications[$i-1];
                        my $current_notify_node = $processed_notifications[$i];
                        process_node_relationships_immediately($prior_notify_node, $current_notify_node, 'dependency', $registry);
                    }
                }
                
                # Process conditional notifications: create/find each conditional notification target and immediately establish relationship
                for my $notif_field (qw(notifies_on_success notifies_on_failure)) {
                    if ($entry->{$notif_field} && ref($entry->{$notif_field}) eq 'ARRAY') {
                        my $condition_type = $notif_field eq 'notifies_on_success' ? 'success' : 'failure';
                        my $context = {
                            global_defaults => $global_defaults,
                            args => $node->args,
                            child_merged_args => $node->args,  # For top-level nodes, use args as child_merged_args
                            node_global_defaults => $node_global_defaults,
                            task_by_name => $task_by_name,
                            platform_by_name => $platform_by_name,
                            group_by_name => $group_by_name,
                            cfg => $cfg,
                            worklist => \@worklist
                        };
                        
                        my @processed_notifications = process_conditional_notifications($node, $entry->{$notif_field}, $condition_type, $registry, $context);
                        
                        # Handle sequential notification dependencies for conditional notifications
                        for my $i (1..$#processed_notifications) {
                            my $prior_notify_node = $processed_notifications[$i-1];
                            my $current_notify_node = $processed_notifications[$i];
                            process_node_relationships_immediately($prior_notify_node, $current_notify_node, 'dependency', $registry);
                        }
                    }
                }
            }
        }
    }
    
    # CRITICAL: Inject sequential group dependencies to establish proper execution order
    # This ensures children of sequential groups depend on their previous siblings
    # Must happen after all nodes and relationships are created
    log_debug("build_graph_with_worklist: injecting sequential group dependencies");
    my $root_node = $registry->get_node_by_name_and_args($root_name, $merged_root_args);
    if ($root_node) {
        inject_sequential_group_dependencies($root_node, $registry);
    }
    log_debug("build_graph_with_worklist: sequential group dependencies injected");
    
    # Find the root node by name and args
    return $root_node;
}

# --- Process notification relationships from config ---
# WHAT: Processes notification arrays from config entries and returns BuildNode references
# HOW: Looks up notification targets by name and args, creates/finds nodes, establishes relationships
# WHY: Enables proper notification setup during build graph construction
sub process_notification_relationships {
    my ($source_node, $notifies_ref, $registry, $context) = @_;
    
    my @processed_notifications = ();
    
    # Handle case where notifies is a single item (not an array)
    my @notifies = ref($notifies_ref) eq 'ARRAY' ? @$notifies_ref : ($notifies_ref);
    
    for my $notify (@notifies) {
        next unless $notify;
        
        my ($notify_name, $notify_args);
        
        if (ref($notify) eq 'HASH') {
            $notify_name = $notify->{name};
            $notify_args = $notify->{args} || {};
        } elsif (!ref($notify)) {
            $notify_name = $notify;
            $notify_args = {};
        } else {
            next; # Skip invalid notification format
        }
        
        # Create the notification target node using GOCN with deduplication
        my $notify_node = get_or_create_node($notify_name, $notify_args, undef, undef, 'notification', $context->{global_defaults}, $registry, $context->{task_by_name}, $context->{platform_by_name}, $context->{group_by_name}, $context->{cfg}, $context->{global_defaults}, $context->{worklist}, undef, 1);
        
        if ($notify_node) {
            push @processed_notifications, $notify_node;
            
            # Establish the notification relationship
            process_node_relationships_immediately($source_node, $notify_node, 'notify', $registry);
        } else {
            log_debug("Warning: Could not create notification target: $notify_name");
        }
    }
    
    return @processed_notifications;
}

# --- Process conditional notification relationships from config ---
# WHAT: Processes conditional notification arrays from config entries and returns BuildNode references
# HOW: Looks up notification targets by name and args, creates/finds nodes, establishes relationships
# WHY: Enables proper conditional notification setup during build graph construction
sub process_conditional_notifications {
    my ($source_node, $notifies_ref, $condition_type, $registry, $context) = @_;
    
    my @processed_notifications = ();
    
    # Handle case where notifies is a single item (not an array)
    my @notifies = ref($notifies_ref) eq 'ARRAY' ? @$notifies_ref : ($notifies_ref);
    
    for my $notify (@notifies) {
        next unless $notify;
        
        my ($notify_name, $notify_args);
        
        if (ref($notify) eq 'HASH') {
            $notify_name = $notify->{name};
            $notify_args = $notify->{args} || {};
        } elsif (!ref($notify)) {
            $notify_name = $notify;
            $notify_args = {};
        } else {
            next; # Skip invalid notification format
        }
        
        # Create the notification target node using GOCN with deduplication
        my $notify_node = get_or_create_node($notify_name, $notify_args, undef, undef, 'notification', $context->{global_defaults}, $registry, $context->{task_by_name}, $context->{platform_by_name}, $context->{group_by_name}, $context->{cfg}, $context->{global_defaults}, $context->{worklist}, undef, 1);
        
        if ($notify_node) {
            push @processed_notifications, $notify_node;
            
            # Set up conditional notification arrays
            if ($condition_type eq 'success') {
                $notify_node->add_success_notify($source_node);
                $notify_node->set_conditional(1);
                # Also store the target node in the source node's notifies_on_success
                $source_node->add_notifies_on_success($notify_node);
                log_debug("Set up success notification: " . $source_node->name . " -> " . $notify_node->name . " (conditional=" . $notify_node->conditional . ")");
            } else {
                $notify_node->add_failure_notify($source_node);
                $notify_node->set_conditional(1);
                # Also store the target node in the source node's notifies_on_failure
                $source_node->add_notifies_on_failure($notify_node);
                log_debug("Set up failure notification: " . $source_node->name . " -> " . $notify_node->name . " (conditional=" . $notify_node->conditional . ")");
            }
            
            # Establish the conditional notification relationship
            if ($condition_type eq 'success') {
                process_node_relationships_immediately($source_node, $notify_node, 'notify_on_success', $registry);
            } else {
                process_node_relationships_immediately($source_node, $notify_node, 'notify_on_failure', $registry);
            }
        } else {
            log_debug("Warning: Could not create conditional notification target: $notify_name");
        }
    }
    
    return @processed_notifications;
}

# --- Create dependency parent for nodes with multiple dependencies ---
# WHAT: Creates an auto-generated dependency parent node that coordinates multiple dependencies
# HOW: Creates a group node with dependencies as children, sets up notifications to original node's children
# WHY: Enables proper dependency ordering and coordination without complex scheduler changes
sub create_dependency_parent {
    my ($original_node, $deps_ref, $global_defaults, $args, $node_global_defaults, $registry, $task_by_name, $platform_by_name, $group_by_name, $cfg, $worklist_ref) = @_;
    
    # Debug: log when this function is called
    if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
        log_debug("create_dependency_parent: ENTERING function for node: " . $original_node->name);
    }
    
    # Debug output removed for cleaner logs
    
    # Debug: Log when create_dependency_parent is called
    if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
        log_debug("create_dependency_parent: called for node: " . $original_node->name);
    }
    
    # Create dependency group name
    my $dep_group_name = $original_node->name . "_dependency_group";
    
    # Generate canonical key for dependency group: name + args
    my @dep_group_key_parts = ($dep_group_name);
    if ($args && ref($args) eq 'HASH' && %$args) {
        my @arg_parts;
        for my $arg_key (sort keys %$args) {
            my $arg_value = $args->{$arg_key};
            push @arg_parts, "$arg_key=$arg_value";
        }
        push @dep_group_key_parts, join(',', @arg_parts) if @arg_parts;
    }
    my $dep_group_canonical_key = join('|', @dep_group_key_parts);
    
    # STEP 2: Check if dependency group already exists in registry (BEFORE creating it)
    if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
        log_debug("create_dependency_parent: checking registry for existing dependency group with key: " . $dep_group_canonical_key);
    }
    my $existing_dep_group = $registry->get_node_by_key($dep_group_canonical_key);
    if ($existing_dep_group) {
        if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
            log_debug("create_dependency_parent: found existing dependency group: " . $existing_dep_group->name);
        }
        if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
            log_debug("create_dependency_parent: found existing dependency group " . $existing_dep_group->name . " with canonical key " . $dep_group_canonical_key);
            log_debug("create_dependency_parent: existing dep_group parents: " . scalar(@{$existing_dep_group->{parents} || []}));
        }
        
        # CRITICAL FIX: Ensure parent relationship is established even for existing dependency groups
        if (!$existing_dep_group->has_parent($original_node)) {
            if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
                log_debug("create_dependency_parent: establishing missing parent relationship for existing dependency group");
            }
            $existing_dep_group->add_parent($original_node);
            $original_node->add_child($existing_dep_group);
        }
        
        return $existing_dep_group;
    }
    
    # STEP 3: Create dependency group entry (group node) - only if it doesn't exist
    my $dep_group_entry = {
        name => $dep_group_name,
        type => 'group',
        parallel => 1,  # Dependencies can run in parallel by default
        continue_on_error => 1,  # Continue even if some dependencies fail
        targets => []
    };
    
    # Add dependencies as children with child_order
    for my $i (0..$#$deps_ref) {
        my $dep = $deps_ref->[$i];
        my ($dep_name, $dep_args);
        
        if (ref($dep) eq 'HASH' && $dep->{name}) {
            $dep_name = $dep->{name};
            # Get the dependency config entry to access its command for selective global merging
            my $dep_entry = load_config_entry($dep_name, $task_by_name, $platform_by_name, $group_by_name, $cfg, $global_defaults);
            my $dep_command = $dep_entry ? ($dep_entry->{command} // $dep_entry->{build_command} // '') : '';
            $dep_args = merge_args($dep_command, $dep->{args}, $args, $global_defaults);
        } elsif (!ref($dep)) {
            $dep_name = $dep;
            # Get the dependency config entry to access its command for selective global merging
            my $dep_entry = load_config_entry($dep_name, $task_by_name, $platform_by_name, $group_by_name, $cfg, $global_defaults);
            my $dep_command = $dep_entry ? ($dep_entry->{command} // $dep_entry->{build_command} // '') : '';
            $dep_args = merge_args($dep_command, undef, $args, $global_defaults);
        } else {
            next;
        }
        
        # Add dependency as child with child_order
        push @{ $dep_group_entry->{targets} }, {
            name => $dep_name,
            args => $dep_args,
            child_order => $i + 1
        };
    }
    
    # Create the dependency group node
    my $dep_group_node = build_and_register_node($dep_group_entry, $args, $registry, $task_by_name, $platform_by_name, $group_by_name, $dep_group_canonical_key);
    return undef unless $dep_group_node;
    
    # Set child_order to 0 for dependency groups
    $dep_group_node->set_child_order(0);
    
    # Add dependency group to registry
    if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
        log_debug("create_dependency_parent: Adding dependency group to registry: " . $dep_group_node->name . " with parents: " . scalar(@{$dep_group_node->{parents} || []}));
    }
    $registry->add_node($dep_group_node);
    if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
        log_debug("create_dependency_parent: After adding to registry - dep_group parents: " . scalar(@{$dep_group_node->{parents} || []}));
    }
    
    # Set up parent-child relationship: dependency group is child of original node
    # This ensures proper coordination flow while allowing independent execution
    if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
        log_debug("create_dependency_parent: Before add_parent - dep_group parents: " . scalar(@{$dep_group_node->{parents} || []}));
        log_debug("create_dependency_parent: Calling add_parent: " . $dep_group_node->name . " -> " . $original_node->name);
    }
    $dep_group_node->add_parent($original_node);
    if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
        log_debug("create_dependency_parent: After add_parent - dep_group parents: " . scalar(@{$dep_group_node->{parents} || []}));
    }
    $original_node->add_child($dep_group_node);
    
    # Manually create the dependency group's children (the actual dependencies)
    my $child_order = 1;
    for my $target (@{ $dep_group_entry->{targets} }) {
        my $child_name = $target->{name};
        my $child_args = $target->{args};
        
        log_debug("Creating dependency group child: $child_name for group: " . $dep_group_node->name);
        
        # Create/find the child node using get_or_create_node for proper deduplication
        # Pass dedupe_nodes=1 to enable deduplication for dependency group children
        my $child_node = get_or_create_node($child_name, $child_args, $dep_group_node->key, $dep_group_node, 'child', $node_global_defaults, $registry, $task_by_name, $platform_by_name, $group_by_name, $cfg, $global_defaults, $worklist_ref, undef, 1);
        
        if ($child_node) {
            # Set child_order for the dependency
            $child_node->set_child_order($child_order);
            
            # Establish parent-child relationship
            process_node_relationships_immediately($dep_group_node, $child_node, 'child', $registry);
            
            # Node is already created and registered - no need to add to worklist
            # The dependency group children are fully processed here
            
            $child_order++;
        }
    }
    
    # Do NOT set up dependency relationship to avoid circular dependencies
    # The dependency group is a child for coordination, not a dependency for execution
    # The original node will depend on the dependency group's children directly
    
    # Set up notifications: dependency group notifies the original node when it completes
    # This provides the completion signal after the dependency is satisfied
    $dep_group_node->add_notify_on_success($original_node);
    
    # CRITICAL: Inject sequential dependencies within the dependency group itself
    # This ensures dependencies execute in the correct order (child_order: 1, 2, 3, etc.)
    log_debug("create_dependency_parent: injecting sequential dependencies within dependency group: $dep_group_name");
    inject_sequential_group_dependencies($dep_group_node, $registry);
    log_debug("create_dependency_parent: sequential dependencies injected for dependency group: $dep_group_name");
    
    log_debug("Created dependency group: $dep_group_name for node: " . $original_node->name . " with " . scalar(@$deps_ref) . " dependencies");
    
    return $dep_group_node;
}

# --- Extract global variables from a config hash ---
# Global variables are used for command argument expansion and string interpolation
# throughout the build system, not as environment variables
sub extract_global_vars {
    my ($cfg) = @_;
    my %global_vars;
    
    # Extract from global_vars array
    for my $entry (@{ $cfg->{global_vars} // [] }) {
        $global_vars{$entry->{name}} = $entry->{value};
    }
    
    # Extract top-level variables that are not excluded
    my %reserved = map { $_ => 1 } (
        'tasks', 'platforms', 'build_groups', 'logging', 'exclude_from_globals',
        'name', 'args', 'command', 'type', 'dependencies', 'children'
    );
    my @exclude = @{$cfg->{exclude_from_globals} // []};
    $reserved{$_} = 1 for @exclude;
    
    for my $k (keys %$cfg) {
        next if $reserved{$k};
        if (ref($cfg->{$k}) eq 'HASH' && exists $cfg->{$k}{default}) {
            $global_vars{$k} = $cfg->{$k}{default};
        } else {
            $global_vars{$k} = $cfg->{$k};
        }
    }
    
    return \%global_vars;
}

# --- Extract category defaults that can be overridden ---
# This function extracts category defaults and allows them to be overridden
# by command-line arguments or environment variables, similar to global variables
sub extract_category_defaults {
    my ($cfg, $category) = @_;
    my $defaults_key = "${category}_defaults";
    my $defaults = $cfg->{$defaults_key} // {};
    
    # If the defaults are a hash with a 'default' key, use that
    if (ref($defaults) eq 'HASH' && exists $defaults->{default}) {
        return $defaults->{default};
    }
    
    # Otherwise, return the defaults as-is
    return $defaults;
}

# --- Extract all category defaults ---
# Returns a hash with all category defaults that can be overridden
sub extract_all_category_defaults {
    my ($cfg) = @_;
    my %all_defaults;
    
    # Extract defaults for each category
    for my $category (qw(task platform group)) {
        my $defaults = extract_category_defaults($cfg, $category);
        if (ref($defaults) eq 'HASH') {
            for my $key (keys %$defaults) {
                $all_defaults{"${category}_${key}"} = $defaults->{$key};
            }
        }
    }
    
    return \%all_defaults;
}

sub ensure_config_entry_has_name_and_type {
    my ($entry, $name, $group_by_name, $task_by_name, $platform_by_name) = @_;
    return undef unless $entry;
    
    # If entry is already a BuildNode object, use its accessors to determine type
    if (ref($entry) && UNIVERSAL::can($entry, 'type')) {
        return $entry;
    }
    
    # For hash references, determine type based on lookup tables
    if (ref($entry) eq 'HASH') {
        # Check if this entry exists in the group lookup table
        if (ref($group_by_name) eq 'HASH' && exists $group_by_name->{$name}) {
            return { %$entry, name => $name, type => 'group' };
        }
        # Check if this entry exists in the task lookup table
        if (ref($task_by_name) eq 'HASH' && exists $task_by_name->{$name}) {
            return { %$entry, name => $name, type => 'task' };
        }
        # Check if this entry exists in the platform lookup table
        if (ref($platform_by_name) eq 'HASH' && exists $platform_by_name->{$name}) {
            return { %$entry, name => $name, type => 'platform' };
        }
        
        # If we can't determine the type from lookup tables, check the entry itself
        if (exists $entry->{type}) {
            return { %$entry, name => $name };
        }
        
        # Default to task if we can't determine the type
        return { %$entry, name => $name, type => 'task' };
    }
    
    # For non-hash references, assume task
    return { name => $name, type => 'task' };
}

# --- Load and process a config entry ---
# This helper function consolidates the common pattern of looking up and processing
# config entries from the various lookup tables. It handles the lookup, type
# --- Load and process configuration entry with defaults ---
# WHAT: Loads a configuration entry by name and applies category-specific defaults
# HOW: Looks up entry in appropriate table, ensures name/type, applies category defaults with priority
# WHY: Provides consistent configuration processing with proper default application across all node types
# INTERNAL: This is an internal function used by get_or_create_node, not intended for direct use
sub load_config_entry {
    my ($name, $task_by_name, $platform_by_name, $group_by_name, $cfg, $global_defaults) = @_;
    
    # Look up the entry in the appropriate table
    my $entry = lookup_config_entry($name, $task_by_name, $platform_by_name, $group_by_name);
    
    # Process the entry to ensure it has name and type
    $entry = ensure_config_entry_has_name_and_type($entry, $name, $group_by_name, $task_by_name, $platform_by_name);
    
    # Apply category-specific defaults if config is provided
    if ($cfg && $entry) {
        $entry = apply_category_defaults($entry, $cfg, $global_defaults);
    }
    
    return $entry;
}

# --- Apply category-specific defaults to configuration entry ---
# WHAT: Applies appropriate defaults to a config entry based on its type (task/platform/group)
# HOW: Determines category from type, extracts category defaults, applies only to missing fields
# WHY: Ensures consistent behavior across all nodes while respecting explicit configuration values
# INTERNAL: This is an internal function used by load_config_entry, not intended for direct use
sub apply_category_defaults {
    my ($entry, $cfg, $global_defaults) = @_;
    return $entry unless $entry && ref($entry) eq 'HASH';
    
    my $type = $entry->{type};
    my $category;
    
    # Determine which category this entry belongs to
    if ($type eq 'task') {
        $category = 'task';
    } elsif ($type eq 'platform') {
        $category = 'platform';
    } elsif ($type eq 'group') {
        $category = 'group';
                } else {
        return $entry;  # Unknown type, return as-is
    }
    
    # Get the category defaults
    my $category_defaults = extract_category_defaults($cfg, $category);
    
    # Apply defaults only for fields that don't already exist in the entry
    for my $key (keys %$category_defaults) {
        unless (exists $entry->{$key}) {
            # Priority: category defaults override global variables
            $entry->{$key} = $category_defaults->{$key};
        }
    }
    
    return $entry;
}

# --- Extract target information from config specification ---
# WHAT: Extracts name, arguments, and other properties from a target specification
# HOW: Handles both string and hash reference formats, returns standardized tuple of properties
# WHY: Provides consistent target information extraction regardless of input format
# PUBLIC: This function is part of the public API and can be used by build scripts
sub extract_target_info {
    my ($target) = @_;
    
    my ($name, $args, $notifies, $requires_execution_of, $instance, $notify_on_success, $notify_on_failure);
    
    if (ref($target) eq 'HASH') {
        $name = $target->{name};
        $args = $target->{args};
        $notifies = $target->{notifies};
        $requires_execution_of = $target->{requires_execution_of};
        $instance = $target->{instance};
        $notify_on_success = $target->{notify_on_success};
        $notify_on_failure = $target->{notify_on_failure};
    } else {
        $name = $target;
        $args = undef;
        $notifies = undef;
        $requires_execution_of = undef;
        $instance = undef;
        $notify_on_success = undef;
        $notify_on_failure = undef;
    }
    
    return ($name, $args, $notifies, $requires_execution_of, $instance, $notify_on_success, $notify_on_failure);
}

# --- Resolve instance references for multi-instance tasks ---
# WHAT: Resolves implicit and explicit instance references for tasks that support multiple instances
# HOW: Handles implicit (most recent), explicit (@first, @last), and specific instance references
# WHY: Enables flexible instance management for tasks that need to run multiple times with different parameters
# INTERNAL: This is an internal function used by the build system, not intended for direct use
sub resolve_instance_reference {
    my ($target_name, $instance_spec, $context_instances, $group_name) = @_;
    
    # If no instance specification, use implicit (most recent)
    unless ($instance_spec) {
        my $recent = $context_instances->{$target_name}->[-1];
        if ($recent) {
            return $recent;
        } else {
            # No instances found, return undef (will be treated as implicit)
            return undef;
        }
    }
    
    # Handle special keywords: "@first" and "@last" (reserved for special references)
    if ($instance_spec eq '@first') {
        my $first = $context_instances->{$target_name}->[0];
        if ($first) {
            return $first;
        } else {
            log_warn("Instance '\@first' requested for '$target_name' in group '$group_name' but no instances found");
            return undef;
        }
    }
    
    if ($instance_spec eq '@last') {
        my $last = $context_instances->{$target_name}->[-1];
        if ($last) {
            return $last;
        } else {
            log_warn("Instance '\@last' requested for '$target_name' in group '$group_name' but no instances found");
            return undef;
        }
    }
    
    # Look for specific instance
    for my $inst (@{$context_instances->{$target_name} || []}) {
        if ($inst->{instance} eq $instance_spec) {
            return $inst;
        }
    }
    
    # Instance not found
    log_warn("Instance '$instance_spec' not found for '$target_name' in group '$group_name'");
    return undef;
}

# --- Generate canonical key with instance support ---
# This function generates the canonical key for a node, including instance information


# --- Instance tracking helper ---
# Tracks instances of tasks within a group context
sub track_instance {
    my ($context_instances, $target_name, $instance_spec) = @_;
    
    $context_instances->{$target_name} ||= [];
    
    my $instance_info = {
        name => $target_name,
        instance => $instance_spec,
        timestamp => time()
    };
    
    push @{$context_instances->{$target_name}}, $instance_info;
    return $instance_info;
}

# Add or move the print_build_order_legend subroutine to BuildUtils.pm and export it
sub print_build_order_legend {
    print Term::ANSIColor::colored("Legend:", 'bold'), "\n";
    print Term::ANSIColor::colored("⧉", 'cyan'), " = parallel group, ";
    print Term::ANSIColor::colored("(sequential)", 'yellow'), " = sequential group, ";
    print Term::ANSIColor::colored("├─/└─/│", 'white'), " = parallel structure\n";
    print Term::ANSIColor::colored("Blue", 'blue'), " = task, ";
    print Term::ANSIColor::colored("Green", 'green'), " = platform, ";
    print Term::ANSIColor::colored("Yellow", 'yellow'), " = sequential group, ";
    print Term::ANSIColor::colored("Cyan", 'cyan'), " = parallel group\n";
    print Term::ANSIColor::colored("Bright Black", 'bright_black'), " = dependencies/notifies inline\n";
    print Term::ANSIColor::colored("Bold", 'bold'), " = default/current target\n\n";
}

# Add the print_final_build_order subroutine from build.pl to BuildUtils.pm and export it
sub print_final_build_order {
    my ($node, $prefix, $is_last, $parent_is_parallel, $default_target, $all_nodes) = @_;
    $prefix ||= '';
    $is_last //= 1;
    $parent_is_parallel //= 0;
    $default_target //= '';
    return unless $node;
    # Filter out empty dependency groups from display
    return if is_empty_dependency_group($node);
    my $is_group = $node->is_group;
    my $is_parallel = $is_group && ($node->continue_on_error || $node->parallel);
    my $is_sequential = $is_group && !$is_parallel;
    my $type_color = $is_parallel ? 'cyan' : $is_sequential ? 'yellow' : $node->is_task ? 'blue' : $node->is_platform ? 'green' : 'white';
    my $label = format_node($node, 'default');
    $label = Term::ANSIColor::colored($label, $type_color);
    $label = '⧉ ' . $label . ' (parallel)' if $is_parallel;
    $label .= ' (sequential)' if $is_sequential;
    $label = Term::ANSIColor::colored($label, 'bold') if $node->name eq $default_target;
    # Show notifications inline (dependencies will be shown as separate nodes)
    my $extra = '';
    my @all_notify_names;
    
    # Process unconditional notifications
    if ($node->can('get_notifies') && @{ $node->get_notifies // [] }) {
        my @notify_names = map { 
            if (ref($_) eq 'HASH' && exists $_->{name}) {
                $_->{name};
            } elsif (ref($_) eq 'HASH' && exists $_->{key}) {
                # Extract name from canonical key (everything before the first |)
                my $key = $_->{key};
                $key =~ s/\|.*$//;
                $key;
            } else {
                'unknown';
            }
        } @{ $node->get_notifies };
        push @all_notify_names, @notify_names;
    }
    
    # Process success notifications
    if ($node->can('get_notifies_on_success') && @{ $node->get_notifies_on_success // [] }) {
        my @success_notify_names = map { 
            if (ref($_) eq 'HASH' && exists $_->{name}) {
                $_->{name};
            } elsif (ref($_) eq 'HASH' && exists $_->{key}) {
                # Extract name from canonical key (everything before the first |)
                my $key = $_->{key};
                $key =~ s/\|.*$//;
                $key;
            } else {
                'unknown';
            }
        } @{ $node->get_notifies_on_success };
        push @all_notify_names, @success_notify_names;
    }
    
    # Process failure notifications
    if ($node->can('get_notifies_on_failure') && @{ $node->get_notifies_on_failure // [] }) {
        my @failure_notify_names = map { 
            if (ref($_) eq 'HASH' && exists $_->{name}) {
                $_->{name};
            } elsif (ref($_) eq 'HASH' && exists $_->{key}) {
                # Extract name from canonical key (everything before the first |)
                my $key = $_->{key};
                $key =~ s/\|.*$//;
                $key;
            } else {
                'unknown';
            }
        } @{ $node->get_notifies_on_failure };
        push @all_notify_names, @failure_notify_names;
    }
    
    $extra .= Term::ANSIColor::colored(' notifies: ', 'bright_black') . join(', ', @all_notify_names) if @all_notify_names && @all_notify_names > 0;
    

    $label .= $extra;
    # Tree lines
    my $branch = '';
    if ($parent_is_parallel) {
        $branch = $is_last ? '└─ ' : '├─ ';
    }
    print $prefix . $branch . $label . "\n";
    my $child_prefix = $prefix;
    if ($parent_is_parallel) {
        $child_prefix .= $is_last ? '    ' : '│   ';
    } else {
        $child_prefix .= '    ';
    }
    
    # Show only explicit dependencies as separate nodes in the tree (filter out implicit sequential dependencies)
    my $deps = $node->dependencies;
    if ($deps && @$deps) {
        # Define known explicit dependencies from config
        my %explicit_dependencies = (
            'macOS_change_tracking' => ['check-dependencies', 'generate-file-list', 'xcodegen'],
            'iOS_change_tracking' => ['check-dependencies', 'xcodegen'],
            'macOS_tests' => ['check-dependencies', 'xcodegen', 'macOS_change_tracking', 'clean-macos-tests'],
            'iOS_tests' => ['check-dependencies', 'xcodegen', 'iOS_change_tracking', 'clean-ios-tests'],
            'all_tests_runner' => ['check-dependencies', 'xcodegen'],
        );
        
        # Filter to only show explicit dependencies
        my @explicit_deps;
        for my $dep (@$deps) {
            if (ref($dep) && $dep->can('name')) {
                my $node_name = $node->name;
                my $dep_name = $dep->name;
                
                # Check if this is an explicit dependency
                my $is_explicit = 0;
                if (exists $explicit_dependencies{$node_name}) {
                    $is_explicit = grep { $_ eq $dep_name } @{ $explicit_dependencies{$node_name} };
                }
                
                if ($is_explicit) {
                    push @explicit_deps, $dep;
                }
            }
        }
        
        # Display explicit dependencies
        my $n = scalar(@explicit_deps);
        for (my $i = 0; $i < $n; $i++) {
            my $dep = $explicit_deps[$i];
            print_final_build_order($dep, $child_prefix, $i == $n-1, $is_parallel, $default_target, $all_nodes);
        }
    }
    
    # Show children (if any)
    unless ($node->is_leaf) {
        # Filter out empty dependency groups before iterating to properly calculate $is_last
        my @filtered_children = grep { !is_empty_dependency_group($_) } @{ $node->children };
        my $n = scalar(@filtered_children);
        for (my $i = 0; $i < $n; $i++) {
            my $child = $filtered_children[$i];
            print_final_build_order($child, $child_prefix, $i == $n-1, $is_parallel, $default_target, $all_nodes);
        }
    }
    
    # Show notification targets as child nodes (if any)
    if ($node->can('get_notifies') && @{ $node->get_notifies // [] }) {
        my @notify_targets;
        for my $notify (@{ $node->get_notifies }) {
            if (ref($notify) eq 'HASH' && exists $notify->{name}) {
                # Find the actual notification target node in the registry by name
                my $notify_node;
                if (ref($all_nodes) && UNIVERSAL::can($all_nodes, 'all_nodes')) {
                    my $registry_nodes = $all_nodes->all_nodes;
                    for my $reg_key (keys %$registry_nodes) {
                        my $reg_node = $registry_nodes->{$reg_key};
                        if ($reg_node->name eq $notify->{name}) {
                            $notify_node = $reg_node;
                            last;
                        }
                    }
                }
                if ($notify_node) {
                    push @notify_targets, $notify_node;
                }
            }
        }
        
        my $n = scalar(@notify_targets);
        for (my $i = 0; $i < $n; $i++) {
            my $notify_target = $notify_targets[$i];
            print_final_build_order($notify_target, $child_prefix, $i == $n-1, $is_parallel, $default_target, $all_nodes);
        }
    }
}

# --- True Build Order Output with Explicit/Implicit Dependencies and Notifies ---
sub print_true_build_order {
    my ($root, $all_nodes, $opts) = @_;
    $opts ||= {};
    my %printed;
    my @order;
    my $visit;
    $visit = sub {
        my ($node, $parent) = @_;
        my $key = get_key_from_node($node);
        return if $printed{$key}++;
        # First, print all explicit dependencies
        if ($node->dependencies && @{ $node->dependencies }) {
            for my $dep (@{ $node->dependencies }) {
                $visit->($dep, undef);
                my $dep_label = format_node($dep, 'compact');
                print "[explicit] depends on: $dep_label\n" unless $opts->{suppress_dep_lines};
            }
        }
        # Implicit dependencies (sequential group)
        if ($parent && $parent->is_group && !($parent->continue_on_error || $parent->parallel)) {
            my $children = $parent->children;
            for (my $i = 1; $i < @$children; $i++) {
                if ($children->[$i] == $node) {
                    my $prev = $children->[$i-1];
                    $visit->($prev, $parent);
                    my $prev_label = format_node($prev, 'compact');
                    print "[implicit] after: $prev_label\n" unless $opts->{suppress_dep_lines};
                }
            }
        }
        # Notifies
        if ($node->notifies && @{ $node->notifies }) {
            for my $notify (@{ $node->notifies }) {
                my $notify_label;
                if (ref($notify) && UNIVERSAL::can($notify, 'name')) {
                    $notify_label = $notify->name;
                } elsif (ref($notify) eq 'HASH') {
                    if (exists $notify->{key}) {
                        # Extract name from canonical key (everything before the first |)
                        my $key = $notify->{key};
                        $key =~ s/\|.*$//;
                        $notify_label = $key;
                    } elsif (exists $notify->{name}) {
                        $notify_label = $notify->{name};
                    } else {
                        $notify_label = 'unknown';
                    }
                } else {
                    $notify_label = $notify;
                }
                print "[notify] notifies: $notify_label\n" unless $opts->{suppress_dep_lines};
            }
        }
        # Print the node itself
        print format_node($node, 'default') . "\n";
        # Then visit children
        unless ($node->is_leaf) {
            for my $child (@{ $node->children }) {
                $visit->($child, $node);
            }
        }
    };
    $visit->($root, undef);
}

# --- Validation Summary Output ---
sub print_validation_summary {
    my ($group_name, $tree, $all_nodes, $print_legend) = @_;
    $print_legend = 1 unless defined $print_legend;
    print "\n========================================\n";
    print "GROUP: $group_name\n";
    print "========================================\n\n";
    if (!$tree) {
        print Term::ANSIColor::colored("[WARN] No build tree constructed for group '$group_name'.\n", 'yellow');
        return;
    }
    print Term::ANSIColor::colored("Tree View (with notifications):\n", 'cyan');
    
    # Get the registry object to access build order
    my $registry;
    if (ref($all_nodes) && UNIVERSAL::can($all_nodes, 'get_build_order')) {
        $registry = $all_nodes;
    } else {
        # If we only have the hash, we can't get build order - fall back to tree traversal
        log_warn("print_validation_summary: No registry available, falling back to tree traversal");
        _print_tree_traversal($tree, $all_nodes, { show_notifications => 1 });
    }
    
    if ($registry) {
        # Display hierarchical tree with notifications
        print_final_build_order($tree, '', 1, 0, $group_name, $all_nodes);
    }
    
    print Term::ANSIColor::colored("\nBuild Order (true execution order):\n", 'magenta');
    print_build_order_legend() if $print_legend;
    print_final_build_order($tree, '', 1, 0, $group_name, $all_nodes);
}

sub handle_result_hash {
    my ($result, $errors) = @_;
    if ($result->{errors}) {
        push @$errors, @{ $result->{errors} };
    }
    if ($result->{warns}) {
        log_warn($_) for @{ $result->{warns} };
    }
    if ($result->{infos}) {
        log_info($_) for @{ $result->{infos} };
    }
    if ($result->{debugs}) {
        log_debug($_) for @{ $result->{debugs} };
    }
    if ($result->{successes}) {
        log_success($_) for @{ $result->{successes} };
    }
}

# DEPRECATED: This function is no longer used and is slated for removal.
# sub add_node_relationships_to_worklist {
#     ... (function body commented out) ...
# }

# (Function body omitted for brevity in this edit. The actual edit will comment out the full function.)

# Remove from @EXPORT_OK
our @EXPORT_OK = qw(merge_args node_key get_key_from_node format_node traverse_nodes expand_command_args get_node_by_key enumerate_notifications process_node_notifications log_info log_warn log_error log_success log_debug log_verbose log_time $VERBOSITY_LEVEL build_graph_with_worklist extract_global_vars build_config_lookup_tables lookup_config_entry build_and_register_node print_node_tree read_args handle_result_hash print_enhanced_tree print_validation_summary print_parallel_build_order inject_sequential_group_dependencies inject_sequential_dependencies_for_dependencies generate_node_key load_config_entry extract_target_info apply_category_defaults extract_category_defaults extract_all_category_defaults print_final_build_order print_build_order_legend print_true_build_order get_or_create_node process_node_relationships_immediately resolve_instance_reference track_instance generate_canonical_key add_to_ready_queue add_to_ready_pending_parent add_to_groups_ready remove_from_ready_queue remove_from_ready_pending_parent remove_from_groups_ready is_node_in_ready_queue is_node_in_ready_pending_parent is_node_in_groups_ready has_ready_nodes has_ready_pending_parent_nodes has_groups_ready_nodes get_next_ready_node get_next_groups_ready_node get_next_ready_pending_parent_node get_eligible_pending_parent_nodes check_any_parent_in_groups_ready is_successful_completion_status get_ready_pending_parent_size get_groups_ready_size get_ready_queue_size get_total_queue_sizes);

=head1 AUTHOR
Distributed Build System (DBS)
=cut 

sub process_node_notifications {
    my ($completed_node, $registry) = @_;
    
    # Process unconditional notifications (always)
    my @unconditional_notifies = $completed_node->get_notifies();
    for my $notify (@unconditional_notifies) {
        _remove_notifier_from_notifee($completed_node, $notify, $registry);
    }
    
    # Process success notifications (only if successful)
    if ($completed_node->is_successful()) {
        my @success_notifies = $completed_node->get_notifies_on_success();
        for my $notify (@success_notifies) {
            _remove_notifier_from_notifee($completed_node, $notify, $registry);
        }
    }
    
    # Process failure notifications (only if failed)
    if (!$completed_node->is_successful()) {
        my @failure_notifies = $completed_node->get_notifies_on_failure();
        for my $notify (@failure_notifies) {
            _remove_notifier_from_notifee($completed_node, $notify, $registry);
        }
    }
}

sub _remove_notifier_from_notifee {
    my ($notifier, $notifee, $registry) = @_;
    
    # Get the current notified_by list from the notifee
    my @current_notified_by = $notifee->get_notified_by();
    
    # Remove the notifier from the list
    my @updated_notified_by = grep { $_ ne $notifier->key() } @current_notified_by;
    
    # Update the notifee's notified_by list
    $notifee->set_notified_by(\@updated_notified_by);
}

# Queue Management Functions (Blackbox Implementation)
sub add_to_ready_pending_parent {
    my ($node) = @_;
    return unless $node;
    push @main::READY_PENDING_PARENT_NODES, $node;
}

sub add_to_groups_ready {
    my ($node) = @_;
    return unless $node;
    my $node_canonical_key = $node->{canonical_key};
    
    # Debug: log when nodes are added to groups_ready
    if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
        my $node_name = $node->can('name') ? $node->name : 'UNKNOWN';
        my $node_type = $node->can('type') ? $node->type : 'UNKNOWN';
        my $child_order = $node->can('get_child_order') ? $node->get_child_order : 'UNKNOWN';
        log_debug("add_to_groups_ready: ADDING node '$node_name' (type: $node_type, child_order: $child_order) to groups_ready");
    }
    
    $main::GROUPS_READY_NODES{$node_canonical_key} = 1;
}

sub add_to_ready_queue {
    my ($node) = @_;
    return unless $node;
    
    # Debug: log the addition
    if ($VERBOSITY_LEVEL >= 3) {
        my $node_name = $node->can('name') ? $node->name : 'UNKNOWN';
        log_debug("add_to_ready_queue: adding node $node_name to ready queue");
    }
    
    push @main::READY_QUEUE_NODES, $node;
}

sub remove_from_ready_pending_parent {
    my ($node) = @_;
    return unless $node;
    my $target_canonical_key = $node->{canonical_key};
    @main::READY_PENDING_PARENT_NODES = grep { $_->{canonical_key} ne $target_canonical_key } @main::READY_PENDING_PARENT_NODES;
    log_debug("Removed " . $node->name . " from ready_pending_parent");
    
}

sub remove_from_groups_ready {
    my ($node) = @_;
    return unless $node;
    my $node_canonical_key = $node->{canonical_key};
    
    # Debug: log when nodes are removed from groups_ready
    if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
        my $node_name = $node->can('name') ? $node->name : 'UNKNOWN';
        my $node_type = $node->can('type') ? $node->type : 'UNKNOWN';
        my $child_order = $node->can('get_child_order') ? $node->get_child_order : 'UNKNOWN';
        log_debug("remove_from_groups_ready: REMOVING node '$node_name' (type: $node_type, child_order: $child_order) from groups_ready");
    }
    
    delete $main::GROUPS_READY_NODES{$node_canonical_key} if exists $main::GROUPS_READY_NODES{$node_canonical_key};
}

sub remove_from_ready_queue {
    my ($node) = @_;
    return unless $node;
    my $target_canonical_key = $node->{canonical_key};
    my $before_count = scalar(@main::READY_QUEUE_NODES);
    @main::READY_QUEUE_NODES = grep { $_->{canonical_key} ne $target_canonical_key } @main::READY_QUEUE_NODES;
    my $after_count = scalar(@main::READY_QUEUE_NODES);
    if ($VERBOSITY_LEVEL >= 3) {
        log_debug("remove_from_ready_queue: removing node with canonical key $target_canonical_key, before: $before_count, after: $after_count");
    }
}

# Queue Size Helper Functions
sub get_ready_pending_parent_size {
    return scalar(@main::READY_PENDING_PARENT_NODES);
}

sub get_groups_ready_size {
    return scalar(keys %main::GROUPS_READY_NODES);
}

sub get_ready_queue_size {
    return scalar(@main::READY_QUEUE_NODES);
}

sub get_total_queue_sizes {
    return {
        rpp => scalar(@main::READY_PENDING_PARENT_NODES),
        gr => scalar(keys %main::GROUPS_READY_NODES),
        ready => scalar(@main::READY_QUEUE_NODES)
    };
}

sub is_node_in_ready_pending_parent {
    my ($node) = @_;
    return unless $node;
    my $target_canonical_key = $node->{canonical_key};
    return grep { $_->{canonical_key} eq $target_canonical_key } @main::READY_PENDING_PARENT_NODES;
}

sub is_node_in_groups_ready {
    my ($node) = @_;
    return unless $node;
    my $node_canonical_key = $node->{canonical_key};
    return exists $main::GROUPS_READY_NODES{$node_canonical_key};
}

sub is_node_in_ready_queue {
    my ($node) = @_;
    return unless $node;
    my $target_canonical_key = $node->{canonical_key};
    return grep { $_->{canonical_key} eq $target_canonical_key } @main::READY_QUEUE_NODES;
}

sub has_ready_pending_parent_nodes {
    return scalar(@main::READY_PENDING_PARENT_NODES) > 0;
}

sub has_groups_ready_nodes {
    return scalar(keys %main::GROUPS_READY_NODES) > 0;
}

sub has_ready_nodes {
    return scalar(@main::READY_QUEUE_NODES) > 0;
}

sub get_next_ready_node {
    # Find the next node in ready queue that is eligible for execution
    for my $node (@main::READY_QUEUE_NODES) {
        next unless ref($node) && $node->can('key');
        # Note: This function should be called with the status manager available
        # For now, just return the first node
        return $node;
    }
    return undef;
}

sub get_next_groups_ready_node {
    my ($first_key) = keys %main::GROUPS_READY_NODES;
    return $main::GROUPS_READY_NODES{$first_key} if $first_key;
    return undef;
}

sub get_next_ready_pending_parent_node {
    return shift @main::READY_PENDING_PARENT_NODES if @main::READY_PENDING_PARENT_NODES;
    return undef;
}

sub get_eligible_pending_parent_nodes {
    # Return all nodes in RPP that are still pending
    my @eligible = ();
    
    # Debug: Check the array size
    if ($VERBOSITY_LEVEL >= 3) {
        log_debug("get_eligible_pending_parent_nodes: RPP array size in BuildUtils.pm: " . scalar(@main::READY_PENDING_PARENT_NODES));
    }
    
    for my $node (@main::READY_PENDING_PARENT_NODES) {
        next unless ref($node) && $node->can('key');
        # Note: This function should be called with the status manager available
        # For now, just return all nodes
        push @eligible, $node;
    }
    return @eligible;
}

sub process_notifications_for_node {
    my ($node, $registry) = @_;
    
    # Get all notification types for this node
    my @unconditional_notifies = $node->get_notifies();
    my @success_notifies = $node->get_notifies_on_success();
    my @failure_notifies = $node->get_notifies_on_failure();
    
    return {
        unconditional => \@unconditional_notifies,
        success => \@success_notifies,
        failure => \@failure_notifies
    };
}
