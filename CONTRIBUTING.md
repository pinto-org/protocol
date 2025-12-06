# Contributing to Pinto Protocol

Thank you for your interest in contributing to Pinto Protocol! This document provides guidelines and information for contributors.

## Table of Contents

- [Code of Conduct](#code-of-conduct)
- [Getting Started](#getting-started)
- [Development Workflow](#development-workflow)
- [Code Standards](#code-standards)
- [Testing Requirements](#testing-requirements)
- [Pull Request Process](#pull-request-process)
- [Security Considerations](#security-considerations)
- [Community](#community)

## Code of Conduct

This project adheres to a [Code of Conduct](CODE_OF_CONDUCT.md). By participating, you are expected to uphold this code. Please report unacceptable behavior to [frijo@pintofarm.org](mailto:frijo@pintofarm.org).

## Getting Started

### Prerequisites

- Node.js 16+ and Yarn
- Foundry (for Solidity development and testing)
- Git for version control

### Initial Setup

1. **Fork and Clone**
   ```bash
   git clone https://github.com/your-username/protocol.git
   cd protocol
   ```

2. **Install Dependencies**
   ```bash
   yarn install
   forge install
   ```

3. **Compile Contracts**
   ```bash
   forge build
   ```

4. **Run Tests**
   ```bash
   forge test           # Foundry tests
   yarn test            # Hardhat tests
   ```

### Understanding the Codebase

Before contributing, familiarize yourself with:

- **[CLAUDE.md](CLAUDE.md)**: Comprehensive protocol architecture guide
- **Core Concepts**: Algorithmic stablecoin mechanics, Season system, Weather system
- **Architecture**: Diamond pattern (EIP-2535), facet structure
- **Economic Mechanisms**: Silo (Pinto's Staking Facility), Field (Pinto's Debt Facility), Sun (Pinto's Timekeeping Facility)

Key directories:
```
contracts/
├── beanstalk/facets/      # Protocol functionality modules
├── beanstalk/storage/     # State management
├── libraries/             # Core logic libraries
└── tokens/                # Token implementations

test/
├── foundry/              # Foundry tests
└── hardhat/              # Hardhat tests
```

## Development Workflow

### Branching Strategy

- `master`: Main development branch (use this for PRs)
- Feature branches: `feature/description-of-feature`
- Bugfix branches: `fix/description-of-fix`
- Documentation: `docs/description-of-update`

### Making Changes

1. **Create a Feature Branch**
   ```bash
   git checkout -b feature/your-feature-name
   ```

2. **Make Your Changes**
   - Write clear, focused commits
   - Follow our code standards (see below)
   - Add tests for new functionality
   - Update documentation as needed

3. **Test Thoroughly**
   ```bash
   forge test -vvv          # Verbose test output
   forge test --match-test testFunctionName  # Run specific test
   ```

4. **Format Code**
   ```bash
   ./scripts/format-sol.sh              # Format all files
   ./scripts/format-sol.sh --staged     # Format staged files only
   ```

5. **Commit Changes**
   ```bash
   git add .
   git commit -m "type: clear description of changes"
   ```

   Commit types: `feat`, `fix`, `docs`, `test`, `refactor`, `chore`

## Code Standards

### Solidity Guidelines

1. **Formatting**
   - Use the project's Forge formatter: `./scripts/format-sol.sh`
   - 4-space indentation
   - Clear, descriptive variable names
   - Comprehensive comments for complex logic

2. **Best Practices**
   - Follow [Solidity Style Guide](https://docs.soliditylang.org/en/latest/style-guide.html)
   - Use SafeMath patterns for arithmetic operations
   - Emit events for state changes
   - Add NatSpec documentation for public functions
   - Keep functions focused and modular

3. **Security**
   - Check for reentrancy vulnerabilities
   - Validate all inputs
   - Use `require` statements with clear error messages
   - Consider gas optimization without sacrificing readability
   - Be especially careful with:
     - Price oracle manipulation
     - Integer overflow/underflow
     - Access control
     - State consistency

4. **Diamond Pattern Considerations**
   - Understand facet boundaries
   - Use AppStorage for shared state
   - Be careful with storage layout changes
   - Test facet interactions thoroughly

### Documentation

- **In-Code Comments**: Explain *why*, not just *what*
- **NatSpec**: Required for all public/external functions
- **README Updates**: Update relevant docs when adding features
- **CLAUDE.md**: Update if changing core protocol mechanics

## Testing Requirements

### Test Coverage

All contributions must include appropriate tests:

1. **Unit Tests**: Test individual functions in isolation
2. **Integration Tests**: Test interactions between components
3. **Fuzz Tests**: Use bounded random inputs for edge cases
4. **Fork Tests**: Test against mainnet state when relevant

### Test Patterns

```solidity
// Use descriptive test names
function test_sowBeans_RevertsWhen_InsufficientApproval() public {
    // Setup
    uint256 amount = 100e6;

    // Test unauthorized access
    vm.expectRevert("Contract: Insufficient approval.");
    field.sow(amount, 1e6, LibTransfer.From.EXTERNAL);
}

// Use fuzz testing for robustness
function testFuzz_sowBeans(uint256 amount) public {
    amount = bound(amount, 1e6, 1000000e6);  // Constrain inputs

    // Test with random valid inputs
    field.sow(amount, 1e6, LibTransfer.From.EXTERNAL);

    // Verify state changes
    assertGt(field.totalSoil(), 0);
}
```

### Running Tests

```bash
# Run all tests
forge test

# Run with verbosity
forge test -vvv

# Run specific test file
forge test --match-path test/foundry/field/Field.t.sol

# Run specific test function
forge test --match-test testFuzz_sowBeans

# Generate coverage report
forge coverage
```

### Test Requirements for PRs

- All new features must have >80% test coverage
- Existing tests must continue to pass
- Add both positive and negative test cases
- Include fuzz tests for functions with numeric inputs
- Test authorization and access control

## Pull Request Process

### Before Submitting

1. **Self-Review Checklist**
   - [ ] Code follows project style guidelines
   - [ ] All tests pass locally
   - [ ] Code is properly formatted (`./scripts/format-sol.sh --check`)
   - [ ] New tests added for new functionality
   - [ ] Documentation updated if needed
   - [ ] Commit messages are clear and descriptive
   - [ ] No unnecessary console logs or debug code

2. **Facet Changes**
   If you modified facet contracts, run impact analysis:
   ```bash
   # In PR comments, mention: @claude analyze facets
   ```
   This provides automated security checklist and impact assessment.

### Submitting the PR

1. **Push to Your Fork**
   ```bash
   git push origin feature/your-feature-name
   ```

2. **Create Pull Request**
   - Target branch: `master`
   - Use a clear, descriptive title
   - Fill out the PR template completely
   - Reference any related issues
   - Add appropriate labels (feature, bugfix, documentation, etc.)

3. **PR Description Should Include**
   - **Summary**: What does this PR do?
   - **Motivation**: Why is this change needed?
   - **Implementation Details**: How does it work?
   - **Testing**: How was this tested?
   - **Breaking Changes**: Any compatibility issues?
   - **Checklist**: Complete the security checklist for critical changes

### PR Review Process

- **Initial Review**: Maintainers review within 3-5 business days
- **Feedback**: Address comments and requested changes
- **Testing**: Automated tests must pass
- **Approval**: Requires approval from at least one core maintainer
- **Merge**: Maintainers will merge once approved

### After Your PR is Merged

- Delete your feature branch (both locally and on GitHub)
- Update your local repository:
  ```bash
  git checkout master
  git pull upstream master
  ```

## Security Considerations

### Critical Areas

When working on these components, extra care is required:

1. **Season/Sun System** (`contracts/beanstalk/facets/sun/`)
   - Core economic adjustments
   - Minting and burning logic
   - State evaluation

2. **Price Oracles** (`contracts/libraries/Oracle/`)
   - Price manipulation vulnerabilities
   - Time-weighted average calculations
   - Multi-market aggregation

3. **Silo** (`contracts/beanstalk/facets/silo/`)
   - Staking rewards calculations
   - Withdrawal mechanisms
   - Governance token distribution

4. **Field** (`contracts/beanstalk/facets/field/`)
   - Debt issuance and repayment
   - Plot transfers
   - Harvestability logic

### Security Review

- High-impact changes undergo additional security review
- External audits may be required for major upgrades
- See [SECURITY.md](SECURITY.md) for vulnerability reporting

## Community

### Communication Channels

- **GitHub Issues**: Bug reports, feature requests, discussions
- **Pull Requests**: Code contributions and reviews
- **Email**: [frijo@pintofarm.org](mailto:frijo@pintofarm.org) for security issues

### Getting Help

- Review [CLAUDE.md](CLAUDE.md) for protocol architecture details
- Check existing issues and discussions
- Ask questions in PR comments
- Reach out to maintainers for guidance

### Types of Contributions Welcome

- 🐛 **Bug Fixes**: Fix issues in existing functionality
- ✨ **Features**: Add new protocol capabilities
- 📚 **Documentation**: Improve guides, comments, and explanations
- 🧪 **Testing**: Add test coverage and improve test quality
- ⚡ **Optimization**: Gas optimizations and efficiency improvements
- 🔍 **Security**: Identify and fix security vulnerabilities
- 🎨 **Code Quality**: Refactoring and code improvements

### Recognition

Contributors will be:
- Listed in repository contributors
- Credited in release notes for significant contributions
- Acknowledged in project documentation

## Questions?

If you have questions about contributing, please:
1. Check existing documentation
2. Search closed issues and PRs
3. Open a new issue with the "question" label
4. Reach out to maintainers directly for sensitive matters

Thank you for contributing to Pinto Protocol! 🌱
