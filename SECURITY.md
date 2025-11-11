# Security Policy

## Overview

The security of the Pinto Protocol is of paramount importance. As an algorithmic stablecoin protocol managing real economic value, we take all security concerns seriously and appreciate responsible disclosure of vulnerabilities.

## Reporting a Vulnerability

### 🚨 **DO NOT** open public GitHub issues for security vulnerabilities

Security vulnerabilities should be reported privately to protect users and give us time to address the issue before public disclosure.

### How to Report

**Primary Method - Immunefi Bug Bounty Program**:

🔗 **[Submit via Immunefi](https://immunefi.com/bug-bounty/pinto/information/)**

We strongly recommend submitting vulnerabilities through our official Immunefi bug bounty program for:
- Streamlined submission process
- Clear reward structure and payment terms
- Professional mediation and support
- Fast-tracked review and response

**Alternative - Direct Email**: [frijo@pintofarm.org](mailto:frijo@pintofarm.org)

**Subject**: `[SECURITY] Brief description of vulnerability`

### What to Include

Please provide as much detail as possible:

1. **Description**: Clear explanation of the vulnerability
2. **Impact**: Potential consequences and severity assessment
3. **Steps to Reproduce**: Detailed steps or proof-of-concept
4. **Affected Components**: Which contracts/functions are impacted
5. **Suggested Fix**: If you have ideas for remediation
6. **Your Contact Info**: How we can reach you for follow-up

### Example Report

```
Subject: [SECURITY] Potential reentrancy in Field.sow()

Description:
The sow() function in FieldFacet.sol may be vulnerable to reentrancy
attacks due to external calls before state updates.

Impact:
- An attacker could potentially sow Beans multiple times in a single transaction
- Could lead to excess Soil consumption and Pod minting
- Estimated severity: HIGH

Steps to Reproduce:
1. Deploy malicious contract with fallback function
2. Call Field.sow() with malicious contract as recipient
3. In fallback, recursively call sow() again
4. Observe multiple Pod mints for single Bean burn

Affected Components:
- contracts/beanstalk/facets/field/FieldFacet.sol:sow() (line 123)
- contracts/beanstalk/facets/field/abstract/Field.sol

Suggested Fix:
- Move state updates before external calls (checks-effects-interactions)
- Add reentrancy guard to sow() function
- Consider using ReentrancyGuard from OpenZeppelin

Contact: security-researcher@email.com
```

## Response Timeline

We are committed to timely responses:

| Stage | Timeline | Actions |
|-------|----------|---------|
| **Acknowledgment** | Within 48 hours | Confirm receipt and begin assessment |
| **Initial Assessment** | Within 7 days | Severity classification and impact analysis |
| **Fix Development** | Varies by severity | Develop and test fix |
| **Disclosure** | 90 days max | Public disclosure coordinated with reporter |

### Severity Classifications

**Critical (90 days max disclosure)**
- Direct loss of funds
- Unauthorized minting/burning
- Oracle manipulation with economic impact
- Complete protocol compromise

**High (60 days max disclosure)**
- Significant economic impact
- Governance manipulation
- DoS attacks affecting core functionality
- Data integrity issues

**Medium (45 days max disclosure)**
- Limited economic impact
- Temporary service disruption
- Access control bypasses with limited scope

**Low (30 days max disclosure)**
- Informational findings
- Best practice violations
- Minor optimizations

## Bug Bounty Program

### Immunefi Program

Pinto Protocol maintains an active bug bounty program through Immunefi:

🔗 **[View Full Program Details on Immunefi](https://immunefi.com/bug-bounty/pinto/information/)**

The Immunefi platform provides:
- **Professional mediation** between researchers and the protocol team
- **Clear reward structures** with transparent payout terms
- **Standardized submission** process and templates
- **Tracked response times** and status updates
- **Secure communication** channels for sensitive disclosures

### Rewards Overview

Reward amounts are determined based on severity and impact according to the [Immunefi Vulnerability Severity Classification System](https://immunefi.com/immunefi-vulnerability-severity-classification-system-v2-3/):

**Note**: All reward amounts and final determinations are managed through the Immunefi platform. See the [official program page](https://immunefi.com/bug-bounty/pinto/information/) for the most current reward information.

### Out of Scope

❌ The following are NOT eligible for bounties:

- Issues in third-party contracts (Chainlink, Basin DEX, etc.)
- Known issues already disclosed
- Theoretical issues without proof-of-concept
- Gas optimization suggestions (unless creating vulnerability)
- Issues requiring physical access or social engineering
- Issues in testnet deployments
- UI/UX bugs without security impact
- Attacks requiring majority governance control
- Public knowledge or already reported vulnerabilities

**Important**: For the complete and authoritative list of in-scope and out-of-scope items, please refer to the [official Immunefi program page](https://immunefi.com/bug-bounty/pinto/information/).

### Submission Guidelines

When submitting through Immunefi, please include:

1. **Vulnerability Description**: Clear explanation of the issue
2. **Impact Assessment**: Potential consequences using Immunefi severity framework
3. **Proof of Concept**: Detailed reproduction steps or working exploit code
4. **Affected Components**: Specific contracts, functions, and line numbers
5. **Suggested Remediation**: Your recommendations for fixing the issue (optional but valued)

**Best Practices**:
- Use the Immunefi platform's structured submission form
- Provide a runnable PoC when possible (Foundry test format preferred)
- Include all relevant transaction hashes or contract interactions
- Follow responsible disclosure practices
- Do not test on mainnet without explicit permission

### Payment Process

All payments are processed through Immunefi's platform:

1. Vulnerability submitted via Immunefi
2. Initial triage and validation by protocol team
3. Severity assessment and impact determination
4. Reward calculation based on Immunefi standards
5. Payment processed through Immunefi (crypto)
6. Public acknowledgment (with researcher's permission)

## Security Best Practices for Contributors

### General Guidelines

When contributing to Pinto Protocol, follow these security principles:

1. **Checks-Effects-Interactions Pattern**
   ```solidity
   // ✅ GOOD: State changes before external calls
   function withdraw() external {
       uint256 amount = balances[msg.sender];
       balances[msg.sender] = 0;  // Effect
       payable(msg.sender).transfer(amount);  // Interaction
   }

   // ❌ BAD: External call before state changes
   function withdraw() external {
       payable(msg.sender).transfer(balances[msg.sender]);  // Interaction
       balances[msg.sender] = 0;  // Effect (too late!)
   }
   ```

2. **Input Validation**
   ```solidity
   // Always validate inputs
   require(amount > 0, "Amount must be positive");
   require(recipient != address(0), "Invalid recipient");
   require(amount <= maxAmount, "Amount exceeds maximum");
   ```

3. **Access Control**
   ```solidity
   // Use modifiers for access control
   modifier onlyOwner() {
       require(msg.sender == owner, "Not authorized");
       _;
   }
   ```

4. **Integer Safety**
   ```solidity
   // Be aware of overflow/underflow
   // Solidity 0.8+ has built-in overflow checks
   uint256 result = a + b;  // Will revert on overflow
   ```

5. **Oracle Price Manipulation**
   - Use time-weighted averages
   - Multiple price sources when possible
   - Validate price deviations
   - Consider flash loan resistance

### Critical Areas Requiring Extra Care

#### 1. Season System (`contracts/beanstalk/facets/sun/`)
- Minting and burning calculations
- State evaluation logic
- Weather system (temperature/soil)
- Ensure atomic state transitions

#### 2. Oracle Integration (`contracts/libraries/Oracle/`)
- Price manipulation resistance
- Time-weighted average calculations
- Fallback mechanisms
- Price deviation bounds

#### 3. Silo Rewards (`contracts/beanstalk/facets/silo/`)
- Stalk and seed calculations
- Deposit and withdrawal accounting
- Grown stalk distribution
- Rounding errors in reward distribution

#### 4. Field Mechanics (`contracts/beanstalk/facets/field/`)
- Pod minting calculations
- Harvestability checks
- Plot transfer logic
- Temperature (interest rate) application

#### 5. Diamond Proxy (`contracts/beanstalk/Diamond.sol`)
- Facet upgrade mechanisms
- Storage collision prevention
- Initialization security
- Selector conflicts

### Testing for Security

Security-focused testing practices:

```solidity
// Test authorization
function test_RevertWhen_Unauthorized() public {
    vm.prank(attacker);
    vm.expectRevert("Not authorized");
    contract.sensitiveFunction();
}

// Test boundaries
function testFuzz_BoundaryConditions(uint256 amount) public {
    amount = bound(amount, 1, type(uint256).max);
    // Test with extreme values
}

// Test reentrancy protection
function test_RevertWhen_Reentrant() public {
    MaliciousContract attacker = new MaliciousContract();
    vm.expectRevert("ReentrancyGuard: reentrant call");
    attacker.attack(address(contract));
}

// Test state consistency
function test_StateConsistency() public {
    uint256 before = contract.totalSupply();
    contract.someOperation();
    uint256 after = contract.totalSupply();
    assertEq(after - before, expectedChange);
}
```

## Audits and Security Reviews

### Completed Audits

We maintain transparency about security audits:

- **Audit Firm**: [To be completed]
- **Date**: [To be completed]
- **Report**: [Link to audit report]
- **Status**: [All findings addressed / In progress]

### Continuous Security

- Regular internal code reviews
- Automated security scanning with Slither
- Formal verification for critical components
- Community security reviews encouraged
- Ongoing monitoring of similar protocols

## Deployment Security

### Mainnet Deployment Checklist

Before deploying to mainnet:

- [ ] All tests passing (unit, integration, fuzz)
- [ ] External audit completed and findings addressed
- [ ] Internal security review completed
- [ ] Formal verification for critical math
- [ ] Timelock on admin functions
- [ ] Emergency pause mechanism tested
- [ ] Upgrade mechanisms secured
- [ ] Oracle manipulation resistance verified
- [ ] Gas optimization completed
- [ ] Documentation updated

### Monitoring

Post-deployment security:

- Real-time monitoring of key metrics
- Anomaly detection for unusual patterns
- Oracle price feed monitoring
- On-chain event monitoring
- Community reporting channels

## Emergency Response

### Emergency Contacts

In case of active exploit or emergency:

**Primary**: Submit critical finding immediately via [Immunefi](https://immunefi.com/bug-bounty/pinto/information/) with "Critical" severity

**Alternative Emergency Contact**: [frijo@pintofarm.org](mailto:frijo@pintofarm.org)

**Subject**: `[EMERGENCY] Active exploit in progress`

### Emergency Pause

The protocol includes emergency pause functionality:

- Can be triggered by authorized addresses
- Prevents critical operations during investigation
- Time-locked unpause to prevent abuse
- Transparent activation with public disclosure

### Post-Incident Process

1. **Immediate Response**: Pause affected functionality
2. **Assessment**: Evaluate scope and impact
3. **Remediation**: Develop and test fix
4. **Recovery**: Deploy fix and resume operations
5. **Post-Mortem**: Public disclosure of incident and lessons learned

## Disclosure Policy

### Coordinated Disclosure

We follow responsible disclosure practices:

1. **Private Reporting**: Security issues reported privately
2. **Development**: Fix developed and tested internally
3. **Review**: External security review of fix if needed
4. **Deployment**: Fix deployed to production
5. **Public Disclosure**: Issue disclosed after fix is live
6. **Credit**: Reporters acknowledged (with permission)

### Timeline

- Maximum 90 days from report to public disclosure
- Can be extended by mutual agreement
- Early disclosure if active exploitation detected
- Coordination with reporter on disclosure content

## Contact

- **Bug Bounty Submissions**: [Immunefi Program](https://immunefi.com/bug-bounty/pinto/information/)
- **Security Issues**: [frijo@pintofarm.org](mailto:frijo@pintofarm.org)
- **General Inquiries**: GitHub Issues (non-security)

---

**Remember**: The security of the protocol depends on responsible disclosure. Thank you for helping keep Pinto Protocol secure! 🛡️
