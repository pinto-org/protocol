#!/bin/bash

# Solidity Formatter Script
# Formats all Solidity files or specific files/directories

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}🎨 Solidity Auto-Formatter${NC}"
echo "=================================="

# Check if prettier is installed
if ! command -v prettier &> /dev/null; then
    echo -e "${RED}❌ Prettier not found. Installing...${NC}"
    npm install --global prettier prettier-plugin-solidity
fi

# Check if .prettierrc exists
if [ ! -f .prettierrc ]; then
    echo -e "${YELLOW}⚠️  No .prettierrc found. Using default configuration.${NC}"
else
    echo -e "${GREEN}✅ Using existing .prettierrc configuration${NC}"
fi

# Function to format files
format_files() {
    local files="$1"
    local count=0
    
    for file in $files; do
        if [ -f "$file" ] && [[ "$file" == *.sol ]]; then
            echo "Formatting: $file"
            prettier --write "$file"
            ((count++))
        fi
    done
    
    echo -e "${GREEN}✨ Formatted $count Solidity files${NC}"
}

# Parse command line arguments
if [ $# -eq 0 ]; then
    # No arguments - format all .sol files
    echo "Formatting all Solidity files in contracts/ directory..."
    SOL_FILES=$(find contracts/ -name "*.sol" 2>/dev/null || true)
    
    if [ -z "$SOL_FILES" ]; then
        echo -e "${YELLOW}📁 No Solidity files found in contracts/ directory${NC}"
        exit 0
    fi
    
    format_files "$SOL_FILES"
    
elif [ "$1" = "--check" ]; then
    # Check mode - just verify formatting without changing files
    echo "Checking Solidity file formatting..."
    SOL_FILES=$(find contracts/ -name "*.sol" 2>/dev/null || true)
    
    if [ -z "$SOL_FILES" ]; then
        echo -e "${YELLOW}📁 No Solidity files found${NC}"
        exit 0
    fi
    
    UNFORMATTED_FILES=""
    for file in $SOL_FILES; do
        if [ -f "$file" ]; then
            if ! prettier --check "$file" > /dev/null 2>&1; then
                UNFORMATTED_FILES="$UNFORMATTED_FILES $file"
            fi
        fi
    done
    
    if [ -n "$UNFORMATTED_FILES" ]; then
        echo -e "${RED}❌ The following files need formatting:${NC}"
        for file in $UNFORMATTED_FILES; do
            echo "  - $file"
        done
        echo ""
        echo -e "${YELLOW}💡 Run './scripts/format-sol.sh' to auto-format these files${NC}"
        exit 1
    else
        echo -e "${GREEN}✅ All Solidity files are properly formatted${NC}"
        exit 0
    fi
    
elif [ "$1" = "--staged" ]; then
    # Format only staged files
    echo "Formatting staged Solidity files..."
    STAGED_SOL_FILES=$(git diff --cached --name-only --diff-filter=ACM | grep -E '\.sol$' || true)
    
    if [ -z "$STAGED_SOL_FILES" ]; then
        echo -e "${YELLOW}📁 No staged Solidity files found${NC}"
        exit 0
    fi
    
    format_files "$STAGED_SOL_FILES"
    
    # Re-stage the formatted files
    for file in $STAGED_SOL_FILES; do
        if [ -f "$file" ]; then
            git add "$file"
        fi
    done
    
    echo -e "${GREEN}✅ Staged files have been formatted and re-staged${NC}"
    
else
    # Format specific files/directories provided as arguments
    echo "Formatting specified files/directories..."
    
    ALL_FILES=""
    for arg in "$@"; do
        if [ -d "$arg" ]; then
            # Directory - find all .sol files in it
            DIR_FILES=$(find "$arg" -name "*.sol" 2>/dev/null || true)
            ALL_FILES="$ALL_FILES $DIR_FILES"
        elif [ -f "$arg" ] && [[ "$arg" == *.sol ]]; then
            # Single .sol file
            ALL_FILES="$ALL_FILES $arg"
        else
            echo -e "${YELLOW}⚠️  Skipping $arg (not a .sol file or directory)${NC}"
        fi
    done
    
    if [ -z "$ALL_FILES" ]; then
        echo -e "${RED}❌ No valid Solidity files found in specified arguments${NC}"
        exit 1
    fi
    
    format_files "$ALL_FILES"
fi

echo ""
echo -e "${GREEN}🎉 Formatting complete!${NC}"

# Optional: Run forge build to verify syntax
if command -v forge &> /dev/null; then
    echo ""
    echo -e "${YELLOW}🔧 Verifying contracts still compile...${NC}"
    if forge build > /dev/null 2>&1; then
        echo -e "${GREEN}✅ All contracts compile successfully${NC}"
    else
        echo -e "${RED}❌ Compilation failed after formatting. Please check for syntax errors.${NC}"
        echo "Run 'forge build' for detailed error information."
        exit 1
    fi
fi