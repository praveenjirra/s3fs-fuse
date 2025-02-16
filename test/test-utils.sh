#!/bin/bash

#### Test utils

set -o errexit
set -o pipefail

# Configuration
TEST_TEXT="HELLO WORLD"
TEST_TEXT_FILE=test-s3fs.txt
TEST_DIR=testdir
ALT_TEST_TEXT_FILE=test-s3fs-ALT.txt
TEST_TEXT_FILE_LENGTH=15
BIG_FILE=big-file-s3fs.txt
BIG_FILE_LENGTH=$((25 * 1024 * 1024))
export RUN_DIR

if [ `uname` = "Darwin" ]; then
    export SED_BUFFER_FLAG="-l"
else
    export SED_BUFFER_FLAG="--unbuffered"
fi

function get_xattr() {
    if [ `uname` = "Darwin" ]; then
        xattr -p "$1" "$2"
    else
        getfattr -n "$1" --only-values "$2"
    fi
}

function set_xattr() {
    if [ `uname` = "Darwin" ]; then
        xattr -w "$1" "$2" "$3"
    else
        setfattr -n "$1" -v "$2" "$3"
    fi
}

function del_xattr() {
    if [ `uname` = "Darwin" ]; then
        xattr -d "$1" "$2"
    else
        setfattr -x "$1" "$2"
    fi
}

function mk_test_file {
    if [ $# == 0 ]; then
        TEXT=$TEST_TEXT
    else
        TEXT=$1
    fi
    echo $TEXT > $TEST_TEXT_FILE
    if [ ! -e $TEST_TEXT_FILE ]
    then
        echo "Could not create file ${TEST_TEXT_FILE}, it does not exist"
        exit 1
    fi

    # wait & check
    BASE_TEXT_LENGTH=`echo $TEXT | wc -c | awk '{print $1}'`
    TRY_COUNT=10
    while true; do
        MK_TEXT_LENGTH=`wc -c $TEST_TEXT_FILE | awk '{print $1}'`
        if [ $BASE_TEXT_LENGTH -eq $MK_TEXT_LENGTH ]; then
            break
        fi
        TRY_COUNT=`expr $TRY_COUNT - 1`
        if [ $TRY_COUNT -le 0 ]; then
            echo "Could not create file ${TEST_TEXT_FILE}, that file size is something wrong"
        fi
        sleep 1
    done
}

function rm_test_file {
    if [ $# == 0 ]; then
        FILE=$TEST_TEXT_FILE
    else
        FILE=$1
    fi
    rm -f $FILE

    if [ -e $FILE ]
    then
        echo "Could not cleanup file ${TEST_TEXT_FILE}"
        exit 1
    fi
}

function mk_test_dir {
    mkdir ${TEST_DIR}

    if [ ! -d ${TEST_DIR} ]; then
        echo "Directory ${TEST_DIR} was not created"
        exit 1
    fi
}

function rm_test_dir {
    rmdir ${TEST_DIR}
    if [ -e $TEST_DIR ]; then
        echo "Could not remove the test directory, it still exists: ${TEST_DIR}"
        exit 1
    fi
}

# Create and cd to a unique directory for this test run
# Sets RUN_DIR to the name of the created directory
function cd_run_dir {
    if [ "$TEST_BUCKET_MOUNT_POINT_1" == "" ]; then
        echo "TEST_BUCKET_MOUNT_POINT variable not set"
        exit 1
    fi
    RUN_DIR=$(mktemp -d ${TEST_BUCKET_MOUNT_POINT_1}/testrun-XXXXXX)
    cd ${RUN_DIR}
}

function clean_run_dir {
    if [  -d ${RUN_DIR} ]; then
        rm -rf ${RUN_DIR} || echo "Error removing ${RUN_DIR}"
    fi
}

# Resets test suite
function init_suite {
    TEST_LIST=()
    TEST_FAILED_LIST=()
    TEST_PASSED_LIST=()
}

# Report a passing test case
#   report_pass TEST_NAME
function report_pass {
    echo "$1 passed"
    TEST_PASSED_LIST+=($1)
}

# Report a failing test case
#   report_fail TEST_NAME
function report_fail {
    echo "$1 failed"
    TEST_FAILED_LIST+=($1)
}

# Add tests to the suite
#   add_tests TEST_NAME...
function add_tests {
    TEST_LIST+=("$@")
}

# Log test name and description
#    describe [DESCRIPTION]
function describe {
    echo "${FUNCNAME[1]}: \"$*\""
}

# Runs each test in a suite and summarizes results.  The list of
# tests added by add_tests() is called with CWD set to a tmp
# directory in the bucket.  An attempt to clean this directory is
# made after the test run.  
function run_suite {
   orig_dir=$PWD
   cd_run_dir
   for t in "${TEST_LIST[@]}"; do
       # The following sequence runs tests in a subshell to allow continuation
       # on test failure, but still allowing errexit to be in effect during
       # the test.
       #
       # See:
       #     https://groups.google.com/d/msg/gnu.bash.bug/NCK_0GmIv2M/dkeZ9MFhPOIJ
       # Other ways of trying to capture the return value will also disable
       # errexit in the function due to bash... compliance with POSIX? 
       set +o errexit
       (set -o errexit; $t)
       if [[ $? == 0 ]]; then
           report_pass $t
       else
           report_fail $t
       fi
       set -o errexit
   done
   cd ${orig_dir}
   clean_run_dir

   for t in "${TEST_PASSED_LIST[@]}"; do
       echo "PASS: $t"
   done
   for t in "${TEST_FAILED_LIST[@]}"; do
       echo "FAIL: $t"
   done

   passed=${#TEST_PASSED_LIST[@]} 
   failed=${#TEST_FAILED_LIST[@]} 

   echo "SUMMARY for $0: $passed tests passed.  $failed tests failed."

   if [[ $failed != 0 ]]; then
       return 1
   else
       return 0
   fi
}

function get_ctime() {
    if [ `uname` = "Darwin" ]; then
        stat -f "%c" "$1"
    else
        stat -c %Z "$1"
    fi
}

function get_mtime() {
    if [ `uname` = "Darwin" ]; then
        stat -f "%m" "$1"
    else
        stat -c %Y "$1"
    fi
}

function aws_cli() {
    AWS_ACCESS_KEY_ID=local-identity AWS_SECRET_ACCESS_KEY=local-credential aws s3 --endpoint-url "${S3_URL}" --no-verify-ssl $*
}
