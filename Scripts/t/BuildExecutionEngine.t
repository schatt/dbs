#!/usr/bin/env perl
# BuildExecutionEngine.t - Tests for BuildExecutionEngine module

use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/..";

# Load modules
use_ok('BuildUtils');
use_ok('BuildNode');
use_ok('BuildNodeRegistry');
use_ok('BuildStatusManager');
use_ok('BuildExecutionEngine');

# Initialize global variables needed by BuildUtils
our @READY_PENDING_PARENT_NODES = ();
our @READY_QUEUE_NODES = ();
our %GROUPS_READY_NODES = ();

# Ensure BuildUtils knows about our globals
package main;

# Test 1: Constructor with required parameters
subtest 'Constructor with required parameters' => sub {
    my $registry = BuildNodeRegistry->new;
    my $status_manager = BuildStatusManager->new;
    
    my $engine = BuildExecutionEngine->new(
        registry => $registry,
        status_manager => $status_manager,
    );
    
    ok($engine, 'Engine created successfully');
    isa_ok($engine, 'BuildExecutionEngine');
    is($engine->registry, $registry, 'Registry accessor works');
    is($engine->status_manager, $status_manager, 'Status manager accessor works');
    is($engine->is_dry_run, 0, 'Default is_dry_run is 0');
    is($engine->is_validate, 0, 'Default is_validate is 0');
};

# Test 2: Constructor with all parameters
subtest 'Constructor with all parameters' => sub {
    my $registry = BuildNodeRegistry->new;
    my $status_manager = BuildStatusManager->new;
    my $temp_dir = tempdir(CLEANUP => 1);
    
    my $engine = BuildExecutionEngine->new(
        registry          => $registry,
        status_manager    => $status_manager,
        is_dry_run        => 1,
        is_validate       => 0,
        build_session_dir => $temp_dir,
    );
    
    ok($engine, 'Engine created with all parameters');
    is($engine->is_dry_run, 1, 'is_dry_run set correctly');
    is($engine->is_validate, 0, 'is_validate set correctly');
    is($engine->build_session_dir, $temp_dir, 'build_session_dir set correctly');
};

# Test 3: Constructor validation - missing registry
subtest 'Constructor validation - missing registry' => sub {
    my $status_manager = BuildStatusManager->new;
    
    eval {
        BuildExecutionEngine->new(
            status_manager => $status_manager,
        );
    };
    
    like($@, qr/registry.*required/i, 'Missing registry throws error');
};

# Test 4: Constructor validation - missing status_manager
subtest 'Constructor validation - missing status_manager' => sub {
    my $registry = BuildNodeRegistry->new;
    
    eval {
        BuildExecutionEngine->new(
            registry => $registry,
        );
    };
    
    like($@, qr/status_manager.*required/i, 'Missing status_manager throws error');
};

# Test 5: Simple execution with a single task node
subtest 'Simple execution with single task node' => sub {
    # Reset global queues
    @READY_PENDING_PARENT_NODES = ();
    @READY_QUEUE_NODES = ();
    %GROUPS_READY_NODES = ();
    
    my $registry = BuildNodeRegistry->new;
    my $status_manager = BuildStatusManager->new;
    my $temp_dir = tempdir(CLEANUP => 1);
    
    # Create a simple task node
    my $node = BuildNode->new(
        name => 'simple_task',
        type => 'task',
        command => 'echo "Hello, World!"',
    );
    $node->{canonical_key} = 'simple_task';
    
    # Add node to registry
    $registry->add_node($node);
    
    # Create engine in validate mode
    my $engine = BuildExecutionEngine->new(
        registry          => $registry,
        status_manager    => $status_manager,
        is_validate       => 1,
        build_session_dir => $temp_dir,
    );
    
    # Execute
    my ($success, $execution_order, $statuses, $groups_ready) = $engine->execute();
    
    ok($success, 'Execution succeeded');
    ok(defined $execution_order, 'Execution order returned');
    ok(ref($execution_order) eq 'ARRAY', 'Execution order is an array');
};

# Test 6: Execution with dry-run mode
subtest 'Execution with dry-run mode' => sub {
    # Reset global queues
    @READY_PENDING_PARENT_NODES = ();
    @READY_QUEUE_NODES = ();
    %GROUPS_READY_NODES = ();
    
    my $registry = BuildNodeRegistry->new;
    my $status_manager = BuildStatusManager->new;
    my $temp_dir = tempdir(CLEANUP => 1);
    
    # Create a simple task node
    my $node = BuildNode->new(
        name => 'dry_run_task',
        type => 'task',
        command => 'echo "Dry run test"',
    );
    $node->{canonical_key} = 'dry_run_task';
    
    # Add node to registry
    $registry->add_node($node);
    
    # Create engine in dry-run mode
    my $engine = BuildExecutionEngine->new(
        registry          => $registry,
        status_manager    => $status_manager,
        is_dry_run        => 1,
        build_session_dir => $temp_dir,
    );
    
    # Execute
    my ($success, $execution_order, $statuses, $groups_ready) = $engine->execute();
    
    ok($success, 'Dry-run execution succeeded');
};

# Test 7: Phase methods exist and are callable
subtest 'Phase methods exist' => sub {
    my $registry = BuildNodeRegistry->new;
    my $status_manager = BuildStatusManager->new;
    
    my $engine = BuildExecutionEngine->new(
        registry => $registry,
        status_manager => $status_manager,
    );
    
    can_ok($engine, 'phase1_coordination');
    can_ok($engine, 'phase2_execution_preparation');
    can_ok($engine, 'phase3_actual_execution');
    can_ok($engine, 'execute');
};

# Test 8: Callback injection works
subtest 'Callback injection' => sub {
    my $registry = BuildNodeRegistry->new;
    my $status_manager = BuildStatusManager->new;
    
    my $transition_called = 0;
    my $check_called = 0;
    my $sanitize_called = 0;
    
    my $engine = BuildExecutionEngine->new(
        registry => $registry,
        status_manager => $status_manager,
        transition_node_callback => sub { $transition_called = 1; },
        check_notifications_callback => sub { $check_called = 1; return 1; },
        sanitize_log_name_callback => sub { $sanitize_called = 1; return 'test'; },
    );
    
    ok($engine->{transition_node_callback}, 'Transition callback stored');
    ok($engine->{check_notifications_callback}, 'Check notifications callback stored');
    ok($engine->{sanitize_log_name_callback}, 'Sanitize log name callback stored');
};

done_testing();
