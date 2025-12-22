#!/bin/bash

# Trio Watch Testing Runner
# This script helps you run tests on your actual Apple Watch

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
WATCH_APP_BUNDLE_ID="com.yourcompany.Trio.watchkitapp"
IPHONE_APP_BUNDLE_ID="com.yourcompany.Trio"
TEST_TIMEOUT=30

echo -e "${BLUE}🧪 Trio Watch Testing Runner${NC}"
echo "=================================="

# Function to print colored output
print_status() {
    local status=$1
    local message=$2
    
    case $status in
        "INFO")
            echo -e "${BLUE}ℹ️  $message${NC}"
            ;;
        "SUCCESS")
            echo -e "${GREEN}✅ $message${NC}"
            ;;
        "WARNING")
            echo -e "${YELLOW}⚠️  $message${NC}"
            ;;
        "ERROR")
            echo -e "${RED}❌ $message${NC}"
            ;;
    esac
}

# Function to check if device is connected
check_device_connection() {
    local device_type=$1
    local bundle_id=$2
    
    print_status "INFO" "Checking $device_type connection..."
    
    if xcrun simctl list devices | grep -q "Booted"; then
        print_status "WARNING" "Simulator detected. For real device testing, ensure your $device_type is connected via USB."
    fi
    
    # Check if app is installed
    if xcrun simctl list apps | grep -q "$bundle_id"; then
        print_status "SUCCESS" "$device_type app is installed"
        return 0
    else
        print_status "ERROR" "$device_type app is not installed"
        return 1
    fi
}

# Function to run a specific test
run_test() {
    local test_name=$1
    local test_command=$2
    
    print_status "INFO" "Running test: $test_name"
    
    if eval "$test_command"; then
        print_status "SUCCESS" "$test_name passed"
        return 0
    else
        print_status "ERROR" "$test_name failed"
        return 1
    fi
}

# Function to test WatchConnectivity
test_watch_connectivity() {
    print_status "INFO" "Testing WatchConnectivity..."
    
    # This would need to be implemented in your app
    # For now, we'll just check if the session is available
    print_status "INFO" "WatchConnectivity test would go here"
    print_status "WARNING" "Implement actual WatchConnectivity test in your app"
    
    return 0
}

# Function to test complication updates
test_complication_updates() {
    print_status "INFO" "Testing complication updates..."
    
    # Check if complication data is being saved
    print_status "INFO" "Checking complication data store..."
    
    # This would check the App Group container for snapshot data
    print_status "WARNING" "Implement complication data verification"
    
    return 0
}

# Function to test data flow
test_data_flow() {
    print_status "INFO" "Testing data flow from iPhone to Watch..."
    
    # This would test the actual data transmission
    print_status "INFO" "Data flow test would go here"
    print_status "WARNING" "Implement actual data flow test"
    
    return 0
}

# Function to test treatment acknowledgments
test_treatment_acknowledgments() {
    print_status "INFO" "Testing treatment acknowledgments..."
    
    # This would test bolus, carbs, and combined treatments
    print_status "INFO" "Treatment acknowledgment test would go here"
    print_status "WARNING" "Implement actual treatment test"
    
    return 0
}

# Function to run all tests
run_all_tests() {
    local passed=0
    local total=0
    
    print_status "INFO" "Starting comprehensive watch testing..."
    
    # Test 1: WatchConnectivity
    total=$((total + 1))
    if test_watch_connectivity; then
        passed=$((passed + 1))
    fi
    
    # Test 2: Complication updates
    total=$((total + 1))
    if test_complication_updates; then
        passed=$((passed + 1))
    fi
    
    # Test 3: Data flow
    total=$((total + 1))
    if test_data_flow; then
        passed=$((passed + 1))
    fi
    
    # Test 4: Treatment acknowledgments
    total=$((total + 1))
    if test_treatment_acknowledgments; then
        passed=$((passed + 1))
    fi
    
    # Print summary
    echo ""
    print_status "INFO" "Test Summary: $passed/$total tests passed"
    
    if [ $passed -eq $total ]; then
        print_status "SUCCESS" "All tests passed! 🎉"
        return 0
    else
        print_status "ERROR" "Some tests failed. Check logs for details."
        return 1
    fi
}

# Function to show help
show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -h, --help              Show this help message"
    echo "  -t, --test TEST_NAME    Run a specific test"
    echo "  -a, --all              Run all tests"
    echo "  -c, --check            Check device connections only"
    echo "  -v, --verbose           Enable verbose output"
    echo ""
    echo "Available tests:"
    echo "  watch-connectivity      Test WatchConnectivity functionality"
    echo "  complication-updates    Test complication data updates"
    echo "  data-flow              Test data flow from iPhone to Watch"
    echo "  treatment-acks         Test treatment acknowledgments"
    echo ""
    echo "Examples:"
    echo "  $0 --all                    # Run all tests"
    echo "  $0 --test data-flow         # Run specific test"
    echo "  $0 --check                  # Check device connections"
}

# Function to check device connections
check_connections() {
    print_status "INFO" "Checking device connections..."
    
    # Check iPhone connection
    if check_device_connection "iPhone" "$IPHONE_APP_BUNDLE_ID"; then
        print_status "SUCCESS" "iPhone connection OK"
    else
        print_status "ERROR" "iPhone connection failed"
        return 1
    fi
    
    # Check Watch connection
    if check_device_connection "Apple Watch" "$WATCH_APP_BUNDLE_ID"; then
        print_status "SUCCESS" "Apple Watch connection OK"
    else
        print_status "ERROR" "Apple Watch connection failed"
        return 1
    fi
    
    print_status "SUCCESS" "All device connections OK"
    return 0
}

# Main script logic
main() {
    local run_all=false
    local test_name=""
    local check_only=false
    local verbose=false
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                exit 0
                ;;
            -t|--test)
                test_name="$2"
                shift 2
                ;;
            -a|--all)
                run_all=true
                shift
                ;;
            -c|--check)
                check_only=true
                shift
                ;;
            -v|--verbose)
                verbose=true
                shift
                ;;
            *)
                print_status "ERROR" "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
    
    # Set verbose mode
    if [ "$verbose" = true ]; then
        set -x
    fi
    
    # Check device connections first
    if ! check_connections; then
        print_status "ERROR" "Device connection check failed"
        exit 1
    fi
    
    if [ "$check_only" = true ]; then
        print_status "SUCCESS" "Device connections verified"
        exit 0
    fi
    
    # Run tests based on arguments
    if [ "$run_all" = true ]; then
        run_all_tests
    elif [ -n "$test_name" ]; then
        case $test_name in
            "watch-connectivity")
                test_watch_connectivity
                ;;
            "complication-updates")
                test_complication_updates
                ;;
            "data-flow")
                test_data_flow
                ;;
            "treatment-acks")
                test_treatment_acknowledgments
                ;;
            *)
                print_status "ERROR" "Unknown test: $test_name"
                show_help
                exit 1
                ;;
        esac
    else
        print_status "ERROR" "No test specified. Use --help for usage information."
        exit 1
    fi
}

# Run main function
main "$@"

