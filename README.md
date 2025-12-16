# Distributed Build System (DBS)

A shared build system for managing complex multi-platform projects with dependency tracking, parallel execution, and comprehensive logging.

## Overview

This repository contains the core build system components that can be shared across multiple projects. The build system provides:

- **Dependency Management**: Automatic dependency resolution and ordering
- **Parallel Execution**: Concurrent task execution where possible
- **Platform Support**: Cross-platform build management
- **Comprehensive Logging**: Detailed execution logs and status tracking
- **Validation**: Build configuration validation and cycle detection
- **Flexible Configuration**: YAML-based configuration with inheritance

## Quick Start

### Setting up a new project

1. Clone or copy this repository to your local machine
2. Run the setup script from your project directory:

```bash
# From your project root
/path/to/dbs/setup_project_build_system.sh /path/to/your/project
```

### Using in an existing project

If you already have a project with build system files:

```bash
# From your project root
./Scripts/setup_build_system.sh
```

This will:
- Create backups of existing build system files
- Create symlinks to the shared build system
- Set up buildconfig.yml if needed
- Create a restore script for reverting changes

## Core Components

### Scripts

- **`build.pl`** - Main build script with comprehensive command-line interface
- **`BuildNode.pm`** - Core build node implementation
- **`BuildNodeRegistry.pm`** - Node registry and management
- **`BuildStatusManager.pm`** - Status tracking and management
- **`BuildUtils.pm`** - Utility functions and helpers
- **`prereqs.sh`** - Prerequisites setup script

### Configuration

- **`buildconfig.sample.yml`** - Sample configuration file
- **`buildconfig.yml`** - Project-specific configuration (created during setup)

### Additional Tools

- **`Scripts/release-process.sh.template`** - Generic release process script template
  - Comprehensive release validation and automation
  - Supports multiple project types (Swift, Node.js, Python, etc.)
  - Configurable version extraction, testing, and documentation checks
  - See `Scripts/RELEASE_PROCESS_README.md` for detailed documentation

## Usage

### Basic Commands

```bash
# Show help
./Scripts/build.pl --help

# List available targets
./Scripts/build.pl --list-targets

# Validate configuration
./Scripts/build.pl --validate

# Build a specific target
./Scripts/build.pl --target <target_name>

# Dry run (show what would be done)
./Scripts/build.pl --target <target_name> --dry-run

# Display build order for a target
./Scripts/build.pl --display <target_name>
```

### Advanced Features

```bash
# Debug mode with verbose output
./Scripts/build.pl --target <target> --debug --verbose

# Simulate failures for testing
./Scripts/build.pl --target <target> --dry-run --simulate-failure node1,node2

# Generate sample configuration
./Scripts/build.pl --generate-sample-config

# Print build order as JSON
./Scripts/build.pl --print-build-order-json
```

## Configuration

The build system uses YAML configuration files. Key sections include:

- **`build_groups`**: Define build targets and their dependencies
- **`platforms`**: Platform-specific configurations
- **`tasks`**: Individual build tasks
- **`global_vars`**: Global variables for command expansion

See `buildconfig.sample.yml` for a complete example.

## Project Structure

```
dbs/
├── Scripts/                    # Core build system files
│   ├── build.pl               # Main build script
│   ├── BuildNode.pm           # Build node implementation
│   ├── BuildNodeRegistry.pm   # Node registry
│   ├── BuildStatusManager.pm  # Status management
│   ├── BuildUtils.pm          # Utility functions
│   ├── prereqs.sh             # Prerequisites setup
│   ├── release-process.sh.template  # Release process template
│   └── RELEASE_PROCESS_README.md    # Release process documentation
├── buildconfig.sample.yml     # Sample configuration
├── setup_project_build_system.sh  # Setup script for new projects
├── install_dbs_tools.sh      # Install DBS tools globally
└── README.md                  # This file
```

## Updating

To update to the latest build system:

1. Pull the latest changes from this repository
2. The symlinks in your projects will automatically point to the updated files

## Restoring Local Changes

If you need to restore local build system files:

```bash
# From your project root
./Scripts/restore_build_system.sh
```

This will restore the original files from backups created during setup.

## Development

### Adding New Features

1. Make changes to the core build system files in this repository
2. Test thoroughly with multiple projects
3. Update documentation as needed
4. Commit and push changes

### Testing

The build system includes comprehensive validation:

```bash
# Validate all configurations
./Scripts/build.pl --validate

# Test specific target
./Scripts/build.pl --target <target> --dry-run
```

## Troubleshooting

### Common Issues

1. **Symlink errors**: Ensure the DBS path is correct and accessible
2. **Permission errors**: Make sure scripts are executable (`chmod +x`)
3. **Configuration errors**: Use `--validate` to check configuration
4. **Dependency cycles**: The system will detect and report circular dependencies

### Debug Mode

Use `--debug` and `--verbose` flags for detailed output:

```bash
./Scripts/build.pl --target <target> --debug --verbose
```

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test with multiple projects
5. Submit a pull request

## License

[Add your license information here]

## Support

For issues and questions:
1. Check the troubleshooting section
2. Review the help output: `./Scripts/build.pl --help`
3. Create an issue in the repository
