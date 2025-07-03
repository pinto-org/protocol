# AI Development Rules & Best Practices

## 🤖 AI Agent Guidelines

### Mandatory Practices

#### 1. Always Create Pull Requests
- **Never commit directly to main/master**
- Create feature branches with descriptive names
- Include comprehensive PR descriptions
- Reference related issues when applicable

#### 2. Testing Requirements
- **Must run tests** before creating PR: `forge test`
- If tests fail, **must fix before submitting**
- Add new tests for new functionality
- Verify gas usage hasn't significantly increased

#### 3. Code Quality Standards
- Follow existing naming conventions
- Include natspec comments for public functions
- Use existing libraries (don't reinvent)
- Maintain consistent formatting

#### 4. Security Checklist
- [ ] No hardcoded addresses (use constants or config)
- [ ] Proper access control modifiers
- [ ] Safe math operations (use OpenZeppelin)
- [ ] Input validation on public functions
- [ ] Events emitted for state changes

### Prohibited Actions

#### ❌ Never Do These
- Commit secrets or private keys
- Bypass existing access controls
- Modify core storage structures without review
- Deploy contracts without proper testing
- Create breaking changes without migration plan

#### ❌ High-Risk Operations (Require Extra Caution)
- Modifying `AppStorage` struct
- Changing Diamond proxy configuration
- Updating oracle logic
- Modifying economic parameters
- Adding new facets

### Communication Standards

#### PR Descriptions Must Include
```markdown
## Summary
Brief description of changes

## Changes Made
- Specific list of modifications
- New files created
- Functions added/modified

## Testing
- Tests added/modified
- Manual testing performed
- Gas impact analysis

## Security Considerations
- Access control implications
- Economic impact assessment
- Breaking change analysis
```

#### Issue Responses
- Acknowledge the request clearly
- Break down complex tasks into steps
- Provide ETA when possible
- Ask clarifying questions if unclear

### Code Review Process

#### Self-Review Checklist
- [ ] Code compiles without warnings
- [ ] All tests pass
- [ ] Gas usage is reasonable
- [ ] Documentation is updated
- [ ] No TODO comments left
- [ ] Follows existing patterns

#### Automated Checks
- Forge tests run automatically on PRs
- Code must pass compilation
- No critical security warnings
- Gas usage within acceptable bounds

### Emergency Procedures

#### If Something Goes Wrong
1. **Stop immediately** - Don't try to fix by adding more changes
2. **Document the issue** clearly in PR comments
3. **Revert if necessary** using `git revert`
4. **Ask for human review** using `@team` mention

#### Critical Issues
- Oracle manipulation detected
- Unexpected minting behavior
- Access control bypassed
- Economic parameters corrupted

### Development Environment

#### Required Setup
```bash
# Install dependencies
yarn install
forge install

# Environment variables needed
FORKING_RPC=<mainnet-rpc-url>
ANTHROPIC_API_KEY=<api-key>

# Pre-commit checks
forge build
forge test
```

#### Recommended Tools
- **Foundry** for contract development
- **Hardhat** for integration testing
- **Slither** for security analysis
- **Gas Reporter** for optimization

### Performance Guidelines

#### Gas Optimization Targets
- Season advancement: < 2M gas
- Simple silo operations: < 200K gas
- Convert operations: < 500K gas
- Oracle updates: < 300K gas

#### Code Efficiency
- Minimize storage reads/writes
- Use events for data that doesn't need storage
- Batch operations when possible
- Cache repeated calculations

### Documentation Standards

#### Required Documentation
- Natspec for all public/external functions
- README updates for new features
- Architecture diagrams for complex changes
- Migration guides for breaking changes

#### Code Comments
- Explain **why**, not just **what**
- Document assumptions and constraints
- Note any protocol-specific behavior
- Reference relevant whitepaper sections

This ensures AI agents develop high-quality, secure code that maintains the protocol's integrity.