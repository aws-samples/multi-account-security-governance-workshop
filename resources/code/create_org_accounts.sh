# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# 
# Permission is hereby granted, free of charge, to any person obtaining a copy of this
# software and associated documentation files (the "Software"), to deal in the Software
# without restriction, including without limitation the rights to use, copy, modify,
# merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
# INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
# PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
# HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
# OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
# SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

#!/bin/bash

function usage() {
    printf "usage: create_org_accounts.sh [-h] --account_email ACCOUNT_EMAIL
                                      [--region AWS_REGION]\n"
}

function create_ou() {
    local parent_id ou_name
    local ou_id
    
    parent_id=$1
    ou_name=$2
    
    ou_id=$(aws organizations create-organizational-unit \
        --parent-id "$parent_id" \
        --name="$ou_name" \
        --query 'OrganizationalUnit.[Id]' \
        --output text)

    echo "$ou_id"
}

function create_account() {
    local email email_append account_name
    local new_acct_email
    local request_id

    email=$1
    email_append=$2
    account_name=$3

    if  $(grep -q "+" <<< "$email") 
    then
            new_acct_email=$(sed 's/@/-'"$email_append"'&/' <<< "$email")
    else
            new_acct_email=$(sed 's/@/+'"$email_append"'&/' <<< "$email")
    fi 

    request_id=$(aws organizations create-account \
        --email "$new_acct_email" \
        --account-name "$account_name" \
        --query 'CreateAccountStatus.[Id]' \
        --output text)

    echo "$request_id"
}

function move_account() {
    local account_id source_id destination_id
    
    account_id=$1
    source_id=$2
    destination_id=$3


    aws organizations move-account \
        --account-id "$account_id" \
        --source-parent-id "$source_id" \
        --destination-parent-id "$destination_id"
}

function get_account_id() {
    local req_id
    local account_stat account_id

    req_id=$1
    
    account_stat="PENDING"
    
    while [ "$account_stat" != "SUCCEEDED" ]
    do
        account_stat=$(aws organizations describe-create-account-status \
            --create-account-request-id "$req_id" \
            --query 'CreateAccountStatus.[State]' \
            --output text)
        if [ $account_stat = "FAILED" ]
        then
            exit 1
        fi
        sleep 10
    done

    account_id=$(aws organizations describe-create-account-status \
            --create-account-request-id "$req_id" \
            --query 'CreateAccountStatus.[AccountId]' \
            --output text)

    echo "$account_id"
}

function main() {
    local new_acct_email email role_name region
    local org_id root_ou account_id
    local log_archive_acct_req_id sec_tooling_req_id webapp_req_id
    local sec_ou_id sec_prod_ou_id workloads_ou_id workloads_prod_ou_id
    local log_archive_account_id sec_tooling_account_id webapp_account_id

    region="us-east-1"
    role_name="OrganizationAccountAccessRole"

    while [ "$1" != "" ]; do
        case $1 in
            -e | --account_email )  shift
                                    email=$1
                                    ;;
            -r | --region )        shift
                                    region=$1
                                    ;;
            -h | --help | * )       usage
                                    exit
                                    ;;
        esac
        shift
    done

    if [ "$email" = "" ] || [ "$region" = "" ]
    then
      usage
      exit
    fi

    printf "Checking if organization exists ...\n"

    org_id=$(aws organizations describe-organization \
        --query Organizations.Id \
        -- output text 2>/dev/null)

    if [ $? != 0 ]; then
        printf "Creating organization ...\n"
        org_id=$(aws organizations create-organization \
            --query 'Organization.[Id]' \
            --output text)
    fi

    sleep 10

    printf "Creating LogArchiveProdAccount ...\n"

    log_archive_req_id=$(create_account "$email" "log-archive" \
        "LogArchiveProdAccount")
    log_archive_account_id=$(get_account_id "$log_archive_req_id")

    sleep 5

    root_ou=$(aws organizations list-roots --query 'Roots[0].[Id]' \
        --output text)
    
    printf "Creating Workloads/Prod OU structure ...\n"
    
    workloads_ou_id=$(create_ou $root_ou "Workloads")
    sleep 5
    workloads_prod_ou_id=$(create_ou $workloads_ou_id "Prod")
    sleep 5

    printf "Creating Security/Prod OU structure ...\n"
    
    sec_ou_id=$(create_ou $root_ou "Security")
    sleep 5
    sec_prod_ou_id=$(create_ou $sec_ou_id "Prod")
    sleep 5

    move_account "$log_archive_account_id" "$root_ou" "$sec_prod_ou_id"
    sleep 5

    printf "Creating SecurityToolingProdAccount ...\n"

    sec_tooling_req_id=$(create_account "$email" "security-tooling" \
        "SecurityToolingProdAccount")
    sec_tooling_account_id=$(get_account_id "$sec_tooling_req_id")

    sleep 5

    move_account "$sec_tooling_account_id" "$root_ou" "$sec_prod_ou_id"

    printf "AWS Organization and accounts created!\n"
    exit
}

main "$@"
