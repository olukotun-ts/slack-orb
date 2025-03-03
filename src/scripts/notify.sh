#!/bin/bash
JQ_PATH=/usr/local/bin/jq

BuildMessageBody() {
    # Send message
    #   If sending message, default to custom template,
    #   if none is supplied, check for a pre-selected template value.
    #   If none, error.
    if [ -n "${SLACK_PARAM_CUSTOM:-}" ]; then
        ModifyCustomTemplate
        # shellcheck disable=SC2016
        MSG_BODY=$(echo "$CUSTOM_BODY_MODIFIED")
    else
        # shellcheck disable=SC2154
        if [ -n "${SLACK_PARAM_TEMPLATE:-}" ]; then TEMPLATE="\$$SLACK_PARAM_TEMPLATE"
        elif [ "$CCI_STATUS" = "pass" ]; then TEMPLATE="\$basic_success_1"
        elif [ "$CCI_STATUS" = "fail" ]; then TEMPLATE="\$basic_fail_1"
        else echo "A template wasn't provided nor is possible to infer it based on the job status. The job status: '$CCI_STATUS' is unexpected."; exit 1
        fi

        [ -z "${SLACK_PARAM_TEMPLATE:-}" ] && echo "No message template was explicitly chosen. Based on the job status '$CCI_STATUS' the template '$TEMPLATE' will be used."

        # shellcheck disable=SC2016
        MSG_BODY=$(eval echo "$TEMPLATE")
    fi
    echo $MSG_BODY > /tmp/SLACK_MSG_BODY.json
    SLACK_MSG_BODY=$(envsubst < /tmp/SLACK_MSG_BODY.json)
}

# ToDo: Add OS_VERSION for macos and windows.
DetectOS() {
    case $(uname -s) in
        Darwin)
            OS_NAME="macos"
            ;;
        Linux)
            . /etc/os-release
            OS_NAME=$ID
            ;;
        MSYS*)
            OS_NAME="windows"
            ;;
        *)
            OS_NAME="unknown"
            echo "OS is unknown. Result of command 'uname -s' is not one of [Darwin, Linux, MSYS*]"
            ;;
    esac
    echo "Detected operating system: $OS_NAME"
}

PostToSlack() {
    # Post once per channel listed by the channel parameter
    #    The channel must be modified in SLACK_MSG_BODY

    # shellcheck disable=SC2001
    for i in $(eval echo \""$SLACK_PARAM_CHANNEL"\" | sed "s/,/ /g")
    do
        echo "Sending to Slack Channel: $i"
        SLACK_MSG_BODY=$(echo "$SLACK_MSG_BODY" | jq --arg channel "$i" '.channel += $channel')
        if [ "$SLACK_PARAM_DEBUG" -eq 1 ]; then
            printf "%s\n" "$SLACK_MSG_BODY" > "$SLACK_MSG_BODY_LOG"
            echo "The message body being sent to Slack can be found below. To view redacted values, rerun the job with SSH and access: ${SLACK_MSG_BODY_LOG}"
            echo "$SLACK_MSG_BODY"
        fi
        SLACK_SENT_RESPONSE=$(curl -s -f -X POST -H 'Content-type: application/json' -H "Authorization: Bearer $SLACK_ACCESS_TOKEN" --data "$SLACK_MSG_BODY" https://slack.com/api/chat.postMessage)
        
        if [ "$SLACK_PARAM_DEBUG" -eq 1 ]; then
            printf "%s\n" "$SLACK_SENT_RESPONSE" > "$SLACK_SENT_RESPONSE_LOG"
            echo "The response from the API call to Slack can be found below. To view redacted values, rerun the job with SSH and access: ${SLACK_SENT_RESPONSE_LOG}"
            echo "$SLACK_SENT_RESPONSE"
        fi

        SLACK_ERROR_MSG=$(echo "$SLACK_SENT_RESPONSE" | jq '.error')
        if [ ! "$SLACK_ERROR_MSG" = "null" ]; then
            echo "Slack API returned an error message:"
            echo "$SLACK_ERROR_MSG"
            echo
            echo
            echo "View the Setup Guide: https://github.com/CircleCI-Public/slack-orb/wiki/Setup"
            if [ "$SLACK_PARAM_IGNORE_ERRORS" = "0" ]; then
                exit 1
            fi
        fi
    done
}

ModifyCustomTemplate() {
    # Inserts the required "text" field to the custom json template from block kit builder.
    if [ "$(echo "$SLACK_PARAM_CUSTOM" | jq '.text')" = "null" ]; then
        CUSTOM_BODY_MODIFIED=$(echo "$SLACK_PARAM_CUSTOM" | jq '. + {"text": ""}')
    else
        # In case the text field was set manually.
        CUSTOM_BODY_MODIFIED=$(echo "$SLACK_PARAM_CUSTOM" | jq '.')
    fi
}

InstallCurl() {
    echo "Checking For CURL"
    if command -v curl >/dev/null 2>&1; then
        echo >&2 "CURL is already installed."
        return $?
    else
        command -v curl >/dev/null 2>&1 || { echo >&2 "SLACK ORB ERROR: CURL is required. Please install"; exit 1; }
        return $?
    fi
}

# ToDo: Add Windows installation
InstallEnvsubst() {
    echo "Checking For envsubst"
    if ! command -v envsubst >/dev/null 2>&1; then
        echo "Missing dependency envsubst. Installing..."
        case $OS_NAME in
            alpine)
                apk update
                apk add gettext
                ;;
            macos)
                brew install gettext
                ;;
            ubuntu)
                sudo apt-get update
                sudo apt-get install gettext-base
                ;;
            *)
                echo >&2 "SLACK ORB ERROR: envsubst is required. Please install"; exit 1; 
                ;;
        esac
        command -v envsubst >/dev/null 2>&1
        return $?
    else
        command -v envsubst >/dev/null 2>&1 || { echo >&2 "SLACK ORB ERROR: envsubst is required. Please install"; exit 1; }
        return $?
    fi
}

InstallJq() {
    echo "Checking For jq"
    if ! command -v jq >/dev/null 2>&1; then
        uname -a | grep Darwin > /dev/null 2>&1 && JQ_VERSION=jq-osx-amd64 || JQ_VERSION=jq-linux32
        curl -Ls -o "$JQ_PATH" https://github.com/stedolan/jq/releases/download/jq-1.6/"${JQ_VERSION}"
        chmod +x "$JQ_PATH"
        command -v jq >/dev/null 2>&1
        return $?
    else
        command -v jq >/dev/null 2>&1 || { echo >&2 "SLACK ORB ERROR: jq is required. Please install"; exit 1; }
        return $?
    fi
}

InstallDependencies() {
    InstallCurl
    InstallJq
    InstallEnvsubst
}

FilterBy() {
    if [ -z "$1" ] || [ -z "$2" ]; then
      return
    fi

    # Add the "invert-match" flag to grep if it is set.
    INVERT_MATCH=""
    if [ "$SLACK_PARAM_INVERT_MATCH" -eq 1 ]; then
        INVERT_MATCH="--invert-match"
    fi

    # If any pattern supplied matches the current branch or the current tag, proceed; otherwise, exit with message.
    # However, if the invert_match parameter is set, invert the match.
    FLAG_MATCHES_FILTER="false"
    for i in $(echo "$1" | sed "s/,/ /g"); do
        if echo "$2" | grep -Eq ${INVERT_MATCH:+"$INVERT_MATCH"} "^${i}$"; then
            FLAG_MATCHES_FILTER="true"
            break
        fi
    done
    if [ "$FLAG_MATCHES_FILTER" = "false" ]; then
        # dont send message.
        echo "NO SLACK ALERT"
        echo
        echo "Current reference \"$2\" does not match any matching parameter"
        echo "Current matching pattern: $1"
        exit 0
    fi
}

SetupEnvVars() {
    echo "BASH_ENV file: $BASH_ENV"
    if [ -f "$BASH_ENV" ]; then
        echo "Exists. Sourcing into ENV"
        # shellcheck disable=SC1090
        . $BASH_ENV
    else
        echo "Does Not Exist. Skipping file execution"
    fi
}

CheckEnvVars() {
    if [ -n "${SLACK_WEBHOOK:-}" ]; then
        echo "It appears you have a Slack Webhook token present in this job."
        echo "Please note, Webhooks are no longer used for the Slack Orb (v4 +)."
        echo "Follow the setup guide available in the wiki: https://github.com/CircleCI-Public/slack-orb/wiki/Setup"
    fi
    if [ -z "${SLACK_ACCESS_TOKEN:-}" ]; then
        echo "In order to use the Slack Orb (v4 +), an OAuth token must be present via the SLACK_ACCESS_TOKEN environment variable."
        echo "Follow the setup guide available in the wiki: https://github.com/CircleCI-Public/slack-orb/wiki/Setup"
        exit 1
    fi
    # If no channel is provided, quit with error
    if [ -z "${SLACK_PARAM_CHANNEL:-}" ]; then
       echo "No channel was provided. Enter value for SLACK_DEFAULT_CHANNEL env var, or channel parameter"
       exit 1
    fi
}

ShouldPost() {
    if [ "$CCI_STATUS" = "$SLACK_PARAM_EVENT" ] || [ "$SLACK_PARAM_EVENT" = "always" ]; then
        # In the event the Slack notification would be sent, first ensure it is allowed to trigger
        # on this branch or this tag.
        FilterBy "$SLACK_PARAM_BRANCHPATTERN" "${CIRCLE_BRANCH:-}"
        FilterBy "$SLACK_PARAM_TAGPATTERN" "${CIRCLE_TAG:-}"
        echo "Posting Status"
    else
        # dont send message.
        echo "NO SLACK ALERT"
        echo "This command is set to send an alert on: $SLACK_PARAM_EVENT"
        echo "Current status: ${CCI_STATUS}"
        exit 0
    fi
}

SetupLogs() {
    if [ "$SLACK_PARAM_DEBUG" -eq 1 ]; then
        LOG_PATH="$(mktemp -d 'slack-orb-logs.XXXXXX')"
        SLACK_MSG_BODY_LOG="$LOG_PATH/payload.json"
        SLACK_SENT_RESPONSE_LOG="$LOG_PATH/response.json"

        touch "$SLACK_MSG_BODY_LOG" "$SLACK_SENT_RESPONSE_LOG"
        chmod 0600 "$SLACK_MSG_BODY_LOG" "$SLACK_SENT_RESPONSE_LOG"
    fi
}

# Will not run if sourced from another script.
# This is done so this script may be tested.
ORB_TEST_ENV="bats-core"
if [ "${0#*"$ORB_TEST_ENV"}" = "$0" ]; then
    . "/tmp/SLACK_JOB_STATUS"  # Is this file correctly formatted for Windows? Missing EOF?
    ShouldPost
    SetupEnvVars
    SetupLogs
    CheckEnvVars
    DetectOS
    InstallDependencies
    BuildMessageBody
    PostToSlack
fi