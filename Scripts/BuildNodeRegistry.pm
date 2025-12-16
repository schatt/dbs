package BuildNodeRegistry;

use strict;
use warnings;
use BuildNode;
use Scalar::Util qw(refaddr);
use BuildUtils qw(log_debug log_error log_warn log_info log_success);

sub new {
    my ($class) = @_;
    my $self = { 
        nodes_by_ref => {},    # Primary storage: BuildNode object reference → BuildNode
        key_to_ref => {},      # Lookup mapping: canonical string key → BuildNode object reference
    };
    bless $self, $class;
    return $self;
}

sub add_node {
    my ($self, $node) = @_;
    die "add_node requires a BuildNode object" unless ref($node) && $node->can('name');
    
    # Get the canonical key from the node
    my $canonical_key = $node->{canonical_key};
    if (!defined($canonical_key)) {
        # Fallback: generate key from name and args
        my $name = $node->name;
        my $args = $node->get_args;
        my @key_parts = ($name);
        if ($args && ref($args) eq 'HASH' && %$args) {
            my @arg_parts;
            for my $arg_key (sort keys %$args) {
                my $arg_value = $args->{$arg_key};
                push @arg_parts, "$arg_key=$arg_value";
            }
            push @key_parts, join(',', @arg_parts) if @arg_parts;
        }
        $canonical_key = join('|', @key_parts);
    }
    
    # Store by reference (primary storage)
    $self->{nodes_by_ref}->{$node} = $node;
    
    # Store the key mapping for efficient lookups
    $self->{key_to_ref}->{$canonical_key} = $node;
    
    # Debug logging
    my $addr = refaddr($node);
    log_debug("add_node: node=" . $node->name . " key=$canonical_key addr=$addr");
}

# Add node with a specific key (for backward compatibility)
sub add_node_with_key {
    my ($self, $key, $node) = @_;
    die "add_node_with_key requires a BuildNode object" unless ref($node) && $node->can('name');
    die "add_node_with_key requires a key" unless defined($key);
    
    # Store by reference (primary storage)
    $self->{nodes_by_ref}->{$node} = $node;
    
    # Store the key mapping for efficient lookups
    $self->{key_to_ref}->{$key} = $node;
    
    # Debug logging
    my $addr = refaddr($node);
    log_debug("add_node_with_key: node=" . $node->name . " key=$key addr=$addr");
}

# Removed problematic get_node function - use get_node_by_key or get_node_by_name_and_args instead

# Find a node by its canonical key (for external use during creation phase)
sub get_node_by_key {
    my ($self, $key) = @_;
    
    # Defensive programming: handle undefined keys
    unless (defined($key)) {
        log_debug("get_node_by_key called with undefined key");
        return undef;
    }
    
    my $ref = $self->{key_to_ref}->{$key};
    return $ref ? $self->{nodes_by_ref}->{$ref} : undef;
}

# Find a node by name and arguments (for external use)
# This checks both the base key and the |dep variant to allow deduplication
# between explicit targets and notification/dependency targets
sub get_node_by_name_and_args {
    my ($self, $name, $args) = @_;
    # Generate the canonical key and look it up
    my @key_parts = ($name);
    if ($args && ref($args) eq 'HASH' && %$args) {
        my @arg_parts;
        for my $arg_key (sort keys %$args) {
            my $arg_value = $args->{$arg_key};
            push @arg_parts, "$arg_key=$arg_value";
        }
        push @key_parts, join(',', @arg_parts) if @arg_parts;
    }
    my $canonical_key = join('|', @key_parts);
    
    # First try the exact key
    my $node = $self->get_node_by_key($canonical_key);
    return $node if $node;
    
    # If not found, try with |dep suffix (for deduplication between explicit targets and notifications)
    my $dep_key = "$canonical_key|dep";
    $node = $self->get_node_by_key($dep_key);
    return $node if $node;
    
    # If still not found, try without |dep suffix if the key had it
    if ($canonical_key =~ s/\|dep$//) {
        $node = $self->get_node_by_key($canonical_key);
        return $node if $node;
    }
    
    return undef;
}

# Find nodes by type
sub find_nodes_by_type {
    my ($self, $type) = @_;
    my @found;
    for my $node (values %{ $self->{nodes_by_ref} }) {
        push @found, $node if $node->type eq $type;
    }
    return @found;
}

# Find nodes by name pattern
sub find_nodes_by_name_pattern {
    my ($self, $pattern) = @_;
    my @found;
    for my $node (values %{ $self->{nodes_by_ref} }) {
        push @found, $node if $node->name =~ /$pattern/;
    }
    return @found;
}

sub has_node {
    my ($self, $node_or_key) = @_;
    
    # If it's a string key, check via the key mapping
    if (!ref($node_or_key)) {
        return defined($node_or_key) && exists $self->{key_to_ref}->{$node_or_key};
    }
    
    # If it's a BuildNode object, check by reference
    if (ref($node_or_key) && $node_or_key->can('name')) {
        return defined($node_or_key) && exists $self->{nodes_by_ref}->{$node_or_key};
    }
    
    return 0;
}

sub remove_node {
    my ($self, $node) = @_;
    # Remove from both storage locations
    delete $self->{nodes_by_ref}->{$node};
    
    # Find and remove the key mapping
    for my $key (keys %{ $self->{key_to_ref} }) {
        if ($self->{key_to_ref}->{$key} eq $node) {
            delete $self->{key_to_ref}->{$key};
            last;
        }
    }
}

sub all_nodes {
    my ($self) = @_;
    return $self->{nodes_by_ref};
}

sub all_keys {
    my ($self) = @_;
    # Return BuildNode references instead of string keys
    return values %{ $self->{nodes_by_ref} };
}

# Build from list of nodes
sub build_from_list {
    my ($self, $nodes) = @_;
    for my $node (@$nodes) {
        $self->add_node($node);
    }
}

# Build from tree structure
sub build_from_tree {
    my ($self, $root) = @_;
    my %seen;
    my $recurse;
    $recurse = sub {
        my ($node) = @_;
        
        # Safety check: ensure node is defined and valid
        unless (defined $node && ref($node) && $node->can('name')) {
            log_debug("build_from_tree: skipping undefined or invalid node: " . (defined $node ? ref($node) : 'undef'));
            return;
        }
        
        return if $seen{ $node }++;  # Use BuildNode reference as key
        $self->add_node($node);
        
        # Safety check: ensure children method exists and returns an array
        if ($node->can('children') && ref($node->children) eq 'ARRAY') {
            for my $child (@{ $node->children }) {
                $recurse->($child);
            }
        } else {
            log_debug("build_from_tree: node " . $node->name . " has no children method or invalid children");
        }
    };
    $recurse->($root);
}

# --- Build order generation ---
# _process_notifications(): shared method that processes notification relationships
# Returns: list of [source_key, target_key] pairs for notifications
sub _process_notifications {
    my ($self) = @_;
    my @notifications;
    my $registry_nodes = $self->all_nodes;
    
    # Track processed relationships to avoid infinite loops
    my %processed_relationships;
    
    # Iterate over BuildNode references instead of keys
    for my $node (values %$registry_nodes) {
        # Use centralized notification processing for all notification types
        my %notification_types = (
            'unconditional' => $node->get_notifies // [],
            'success' => $node->get_notifies_on_success // [],
            'failure' => $node->get_notifies_on_failure // []
        );
        
        for my $type (keys %notification_types) {
            for my $notify (@{ $notification_types{$type} }) {
                my ($target_node, $target_key) = BuildUtils::process_notification_target($notify, $self);
                if ($target_node && defined $target_node && $target_key) {
                    # Create a unique relationship key to avoid duplicates
                    my $relationship_key = "$node->$target_node:$type";
                    
                    # Skip if we've already processed this relationship
                    next if $processed_relationships{$relationship_key};
                    $processed_relationships{$relationship_key} = 1;
                    
                    # Only add the reverse relationship (source to target's notified_by)
                    # Don't re-add to source's notification lists (they already exist)
                    $target_node->add_notified_by($node);
                    
                    # Also collect the pair for external processing if needed
                    push @notifications, [$node, $target_node];
                }
            }
        }
    }
    
    return @notifications;
}

# DELETED: _get_dependency_info - was fundamentally broken (used objects as hash keys)

# DELETED: get_build_order - was broken and called deleted _get_dependency_info

# DELETED: Documentation for deleted get_build_order method

# DELETED: get_parallel_build_order - was broken and called deleted _get_dependency_info

# Helper: check if all dependencies of a node are scheduled
sub all_deps_scheduled {
    my ($node, $scheduled) = @_;
    for my $dep (@{ $node->dependencies // [] }) {
        # Handle both BuildNode objects and string dependencies
        my $dep_node;
        if (ref($dep) && $dep->can('name')) {
            # It's a BuildNode object, use it directly
            $dep_node = $dep;
        } else {
            # It's a string dependency, this is an error in the new system
            # Dependencies should be BuildNode references
            return 0;
        }
        return 0 unless $scheduled->{ $dep_node };
    }
    return 1;
}

# --- Cycle Detection with Union-Find ---

=head2 would_create_cycle($source_node, $target_node)

Check if adding a dependency from source to target would create a cycle.
Uses DFS to check if there's already a path from target back to source.

=cut

sub would_create_cycle {
    my ($self, $source_node, $target_node) = @_;
    
    # Both parameters should be BuildNode objects
    die "would_create_cycle requires BuildNode objects, got: " . ref($source_node) . " and " . ref($target_node) unless ref($source_node) && ref($target_node);
    
    # Debug output
    log_debug("DFS cycle check: " . $source_node->name . " -> " . $target_node->name);
    
    # Use DFS to check if there's a path from target back to source
    my %visited;
    my $has_cycle = $self->_dfs_has_path($target_node, $source_node, \%visited);
    
    log_debug("DFS cycle check result: " . ($has_cycle ? "true" : "false"));
    
    return $has_cycle;
}

=head2 _dfs_has_path($start_node, $target_node, $visited)

Helper method to check if there's a path from start_node to target_node.
Uses DFS to traverse the dependency graph.

=cut

sub _dfs_has_path {
    my ($self, $start_node, $target_node, $visited) = @_;
    
    # Mark current node as visited
    $visited->{$start_node} = 1;
    
    # Check if we've reached the target
    return 1 if $start_node eq $target_node;
    
    # Recursively check all dependencies
    for my $dep (@{ $start_node->dependencies // [] }) {
        # Handle both BuildNode objects and string dependencies
        my $dep_node;
        if (ref($dep) && $dep->can('name')) {
            # It's a BuildNode object, use it directly
            $dep_node = $dep;
        } else {
            # It's a string dependency, skip it in the new system
            next;
        }
        
        next if $visited->{$dep_node};  # Skip already visited nodes
        if ($self->_dfs_has_path($dep_node, $target_node, $visited)) {
            return 1;  # Found a path
        }
    }
    
    return 0;  # No path found
}

=head2 add_dependency($source_node, $target_node)

Add a dependency from source to target. Cycle detection should be done before calling this method.

=cut

sub add_dependency {
    my ($self, $source_node, $target_node) = @_;
    
    # Simply add the dependency - cycle detection is handled by the caller
    $source_node->add_dependency($target_node);
}

=head2 _find_cycle_path($source_node, $target_node)

Find the actual cycle path when a cycle is detected.
This is a slower operation used only for error reporting.

=cut

sub _find_cycle_path {
    my ($self, $source_node, $target_node) = @_;
    
    # Since we're adding source -> target, a cycle would be target -> ... -> source
    # We already know this path exists because would_create_cycle() returned true
    my %visited;
    my @path;
    
    my $dfs;
    $dfs = sub {
        my ($current) = @_;
        
        return 1 if $current eq $source_node;  # Found the cycle
        
        $visited{$current} = 1;
        push @path, $current->name;  # Use name for display purposes
        
        for my $dep (@{ $current->dependencies // [] }) {
            # Handle both BuildNode objects and string dependencies
            my $dep_node;
            if (ref($dep) && $dep->can('name')) {
                # It's a BuildNode object, use it directly
                $dep_node = $dep;
            } else {
                # It's a string dependency, skip it in the new system
                next;
            }
            
            next if $visited{$dep_node};
            if ($dfs->($dep_node)) {
                return 1;  # Found the cycle
            }
        }
        
        pop @path;  # Backtrack
        return 0;
    };
    
    $dfs->($target_node);
    
    # Return the cycle path: source -> ... -> target -> source
    return [ $source_node->name, @path, $source_node->name ];
}

1;

__END__

=head1 NAME
BuildNodeRegistry - Central registry for BuildNode objects

=head1 SYNOPSIS
  use BuildNodeRegistry;
  my $reg = BuildNodeRegistry->new;
  $reg->add_node($node);
  my $node = $reg->get_node($key);

=head1 DESCRIPTION
This class manages all BuildNode instances, providing lookup, addition, removal, and traversal. It enforces canonical keying and is the single source of truth for node identity.

=cut 