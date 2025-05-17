#!/bin/bash

export GDK_BACKEND=x11

# Dependency checks
for dep in jq curl zenity; do
: '
Redirect stdout(1) to /dev/null" (i.e., discard it).
Then redirect stderr(2) to the same place as stdout(1) — which is now /dev/null.
'
    if ! command -v "$dep" >/dev/null 2>&1; then
        echo "Error: required dependency '$dep' is not installed." >&2
        if command -v zenity >/dev/null 2>&1; then
            zenity --error --title="Dependency Missing" --text="Required tool '$dep' is not installed. Please install it and try again."
        else
            echo "Required tool '$dep' is not installed. Please install it and try again."
        fi
        exit 1
    fi
done

# Check if DISPLAY is set for Zenity GUI

: '
    env: this command return all environment variables
    | grep : using pipe pass this content to grep 
    -q: flag to use quiet mode (command only returns status codes, not the output)
    ! : if the display variable is not set
'
if ! env | grep -q '^DISPLAY='; then
    echo "Error: DISPLAY environment variable is not set. GUI dialogs will not work."
    echo "If running in Docker, use X11 forwarding or run headless."
    exit 1
fi

# CONFIGURATION & GLOBALS
HISTORY_FILE="./api_tester_history.log"
DEFAULT_HEADERS_FILE="./config/default_headers.conf"
TEMPLATES_DIR="./templates"

# sets max time allowed for the request (in seconds).
CURL_TIMEOUT=20


# -p: avoids error if the directory already exists.
mkdir -p "$TEMPLATES_DIR" 
: '
    declare: a Bash builtin used to define variables with specific attributes.
    -a: tells Bash that this variable should be an indexed array.
'
declare -a DEFAULT_HEADERS

: '
    [[...]]: bash test command for evaluating expressions
    -f: (file test operator)checks is a file exists and is a regular file
    mapfile: reads each line from the file, and stores each line as a element in a DEFAULT_HEADERS (array)
    -t: remove the trailing newline character
'
if [[ -f "$DEFAULT_HEADERS_FILE" ]]; then
    mapfile -t DEFAULT_HEADERS < "$DEFAULT_HEADERS_FILE"
fi

# FUNCTIONS

# Print an error message and return
error_exit() {
    zenity --error --title="Error" --text="$1"
    rm -f /tmp/api_resp.txt /tmp/api_err.txt /tmp/response_display_*.txt 2>/dev/null
    return 1
}

# Main menu UI
show_main_menu() {
    while true; do
        choice=$(zenity --list \
            --title="API Tester" \
            --text="Choose an action:" \
            --column="Option" --column="Description" \
            "New Request" "Create a new API request" \
            "Templates" "Save or load request templates" \
            "History" "View & search request history" \
            "Defaults" "Manage default headers" \
            "Clear History" "Delete all history" \
            "Exit" "Quit the application" \
            --width=600 --height=350)
        case "$choice" in
            "New Request") new_request ;;
            "Templates") manage_templates ;;
            "History") show_history ;;
            "Defaults") manage_defaults ;;
            "Clear History") clear_history ;;
            "Exit"|"") exit 0 ;;
        esac
    done
}

new_request() {
    # HTTP method
    #local : scope only in the function
    local method 
    method=$(zenity --list --title="HTTP Method" --text="Select HTTP method:" --column="Method" GET POST PUT DELETE PATCH --width=600 --height=350) || return 0

    #Checks if the method variable is empty (-z tests for a zero-length string).
    [[ -z "$method" ]] && return 0

    # API URL
    local url
    url=$(zenity --entry --title="API URL" --text="Enter the API endpoint URL (e.g. https://api.example.com/resource):" --width=600 --height=350)
    
    # $? : returns status code of previous command
    # -ne : not equal
    # -z : check fo 0-len string
    if [[ $? -ne 0 || -z "$url" ]]; then
        return 0
    fi

    # Authentication
    local auth_header=""

    auth_type=$(zenity --list --title="Authentication" --text="Choose authentication method (optional):" --column="Type" None "Bearer Token" "API Key (Header)" --width=400 --height=250)
    if [[ $? -ne 0 ]]; then return 0; fi
    if [[ "$auth_type" == "Bearer Token" ]]; then
        local token
        token=$(zenity --entry --title="Bearer Token" --text="Enter Bearer token:" --width=400 --height=200)
        if [[ $? -ne 0 ]]; then return 0; fi
        # checks If either the token is empty or it contains whitespace
        # ~=  Bash regex match operator
        # It tests whether the string on the left side ("$token") matches the regular expression on the right side ([[:space:]]).
        if [[ -z "$token" || "$token" =~ [[:space:]] ]]; then
            error_exit "Invalid Bearer token: Token cannot be empty or contain spaces."
            return 1
        fi
        auth_header="Authorization: Bearer $token"
    elif [[ "$auth_type" == "API Key (Header)" ]]; then
        local keyname keyval
        keyname=$(zenity --entry --title="API Key Header" --text="Header name (e.g., X-API-Key):" --width=400 --height=200)
        if [[ $? -ne 0 ]]; then return 0; fi
        keyval=$(zenity --entry --title="API Key Value" --text="API key value:" --width=400 --height=200)
        if [[ $? -ne 0 ]]; then return 0; fi
        if [[ -z "$keyname" || -z "$keyval" ]]; then
            error_exit "Invalid API Key: Header name and value cannot be empty."
            return 1
        fi
        if [[ "$keyname" =~ [[:space:]:] ]]; then
            error_exit "Invalid header name: '$keyname'. It cannot contain spaces or colons."
            return 1
        fi
        auth_header="$keyname: $keyval"
    fi

    # Ask if user wants to add/modify headers
    local headers=""
    if zenity --question --title="Headers" --text="Do you want to add or modify headers?" --ok-label="Yes" --cancel-label="No"; then
        headers=$(zenity --text-info --editable --title="Headers" --width=600 --height=200 --text="Header: Value\n(one per line, optional)")
        if [[ $? -ne 0 ]]; then return 0; fi
    fi
    # Ask if user wants to add/modify body
    local body=""
    if zenity --question --title="Body" --text="Do you want to add or modify the body?" --ok-label="Yes" --cancel-label="No"; then
        body=$(zenity --text-info --editable --title="Body" --width=600 --height=200 --text="{\n  \"key\": \"value\"\n}\n(Optional, leave blank for GET)")
        if [[ $? -ne 0 ]]; then return 0; fi
    fi

    # Confirm
    zenity --question --title="Confirm" --text="Method: $method\nURL: $url \nProceed?" --width=400 --height=150 || return 0

    # Build the curl command 
    #-s: silent mode, suppress progress output.
    #-X "$method": HTTP method (GET, POST, etc.).
    #--max-time $CURL_TIMEOUT: sets max time allowed for the request (in seconds).
    local cmd="curl -s -X \"$method\" --max-time $CURL_TIMEOUT"

    # Add headers 
    # -n : check for non-empty  ( -z check for 0-len , so ! -z is same as -n)
    if [[ -n "$headers" ]]; then
        # loop to read headers line-by-line.
        while IFS= read -r h; do
        # xargs trims whitespace from each header line.
            h_trimmed=$(echo "$h" | xargs)
            # if h_trimmed is not empty, contaticate it to the command
            [[ -n "$h_trimmed" ]] && cmd+=" -H \"$h_trimmed\""
        # feeds the headers string as input line-by-line to the loop.
        done <<< "$(echo -e "$headers")"
    fi

    for dh in "${DEFAULT_HEADERS[@]}"; do
        dh_trimmed=$(echo "$dh" | xargs)
        [[ -n "$dh_trimmed" ]] && cmd+=" -H \"$dh_trimmed\""
    done

    # Add authentication header if set
    if [[ -n "$auth_header" ]]; then
        cmd+=" -H \"$auth_header\""
    fi

    # Add body only if non-empty, non-whitespace, and not GET
    body_trimmed=$(echo "$body" | xargs)
    if [[ -n "$body_trimmed" && "$method" != "GET" ]]; then
        cmd+=" -d \"$body_trimmed\""
    fi

    cmd+=" \"$url\""
    echo "Full Curl Command: $cmd"

    # Execute these command is a subshell (..), while this subshell complete execution, zenity progress bar is shown
    
    (
        printf "Command: %s\n" "$cmd" > /tmp/curl_debug.txt
        # bash : invokes a new bash shell
        # -c: tells bash to exec the next argument as a command
        # || : control operator for chaining commands, not the boolean expressions
        #command1 || command2
        #command2 only runs if command1 fails (i.e., exits with non-zero).
        # 0: success
        # non-zero: failure
        bash -c "$cmd" > /tmp/api_resp.txt 2>/tmp/api_err.txt || echo "CURL_ERROR" > /tmp/api_resp.txt
    ) | zenity --progress --pulsate --auto-close --no-cancel --title="Sending..." --text="Please wait" --width=600 --height=350

    if grep -q "CURL_ERROR" /tmp/api_resp.txt; then
        error_exit "Failed to contact API endpoint.\n$(cat /tmp/api_err.txt)"
        return 1
    fi

    local raw status time size response
    # copy content of file to raw variable
    raw=$(< /tmp/api_resp.txt)
    status=$(grep -oP '__STATUS__\K[0-9]+' /tmp/api_resp.txt)
    time=$(grep -oP '__TIME__\K[0-9.]+(?=__END__)' /tmp/api_resp.txt)
    size=$(grep -oP '__SIZE__\K[0-9]+' /tmp/api_resp.txt)
    response=${raw//__STATUS__${status}__END__/}
    response=${response//__TIME__${time}__END__/}
    response=${response//__SIZE__${size}__END__/}
    [[ -z "$status" ]] && status="N/A"
    [[ -z "$time" ]] && time="N/A"
    [[ -z "$size" ]] && size="N/A"

    # Prepare response display
    local separator="=================================================="
    local display_file="/tmp/response_display_$$.txt"
    {
        #echo "Status: $status"
        #echo "Time: ${time}s"
        #echo "Size: ${size} bytes"
        #echo "$separator"
        echo "Raw Response:"
        echo "$response"
        # is response json or not
        if command -v jq >/dev/null 2>&1 && echo "$response" | jq . >/dev/null 2>&1; then
            echo "$separator"
            echo "Pretty JSON:"
            echo "$response" | jq .
        fi
    } > "$display_file"
    zenity --text-info --title="Response ($status)" --width=700 --height=500 --filename="$display_file"
    rm -f "$display_file" /tmp/api_resp.txt /tmp/api_err.txt

    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    {
        echo "[$timestamp] $method $url"
        echo "Headers:"
        echo "${headers:-(none)}"
        echo "Body:"
        echo "${body:-(none)}"
        echo "Status: $status"
        echo "Time: $time"
        echo "Size: $size"
        echo "Response:"
        echo "$response"
        echo "---"
    } >> "$HISTORY_FILE"

    if zenity --question --title="Export Response" --text="Export response to file?" --width=400 --height=150; then
        local export_path=$(zenity --file-selection --save --confirm-overwrite --title="Save Response As")
        [[ -n "$export_path" ]] && echo "$response" > "$export_path"
    fi
}


# TEMPLATES LOGIC

manage_templates() {
    action=$(zenity --list --title="Templates" --text="Choose an action:" --column="Action" "Save Current Request" "Load Template" --width=400 --height=200)
    case "$action" in
        "Save Current Request") save_template ;;
        "Load Template") load_template ;;
        *) return ;;
    esac
}

save_template() {
    # Prompt for template name
    tname=$(zenity --entry --title="Save Template" --text="Enter template name:") || return
    # Prompt for request details
    method=$(zenity --list --title="HTTP Method" --text="Select HTTP method:" --column="Method" GET POST PUT DELETE PATCH --width=600 --height=350) || return
    url=$(zenity --entry --title="API URL" --text="Enter the API endpoint URL (e.g. https://api.example.com/resource):" --width=600 --height=350) || return
    headers=$(zenity --text-info --editable --title="Headers" --width=600 --height=200 --text="Header: Value\n(one per line, optional)")
    body=$(zenity --text-info --editable --title="Body" --width=600 --height=200 --text="{\n  \"key\": \"value\"\n}\n(Optional, leave blank for GET)")
    # Ask if user wants to add test cases
    testcases_json="[]"
    if zenity --question --title="Test Cases" --text="Do you want to add test cases to this template?" --ok-label="Yes" --cancel-label="No"; then
    num_cases=$(zenity --entry --title="Number of Test Cases" --text="How many test cases do you want to add?" --entry-text="1")
    if ! [[ "$num_cases" =~ ^[0-9]+$ ]] || [[ "$num_cases" -le 0 ]]; then
        zenity --error --text="Invalid number of test cases."
        num_cases=0
    fi
    testcases_json="["
    for ((i=1; i<=num_cases; i++)); do
        tdesc=$(zenity --entry --title="Test Case $i Description" --text="Describe this test case:") || break
        tmethod=$(zenity --list --title="Test Case $i HTTP Method" --text="Select HTTP method:" --column="Method" GET POST PUT DELETE PATCH --width=600 --height=350) || break
        turl=$(zenity --entry --title="Test Case $i API URL" --text="Enter the API endpoint URL:") || break
        theaders=$(zenity --text-info --editable --title="Test Case $i Headers" --width=600 --height=200 --text="Header: Value\n(one per line, optional)")
        tbody=$(zenity --text-info --editable --title="Test Case $i Body" --width=600 --height=200 --text="{\n  \"key\": \"value\"\n}\n(Optional, leave blank for GET)")
        tstatus=$(zenity --entry --title="Test Case $i Expected Status" --text="Expected HTTP status code (e.g. 200):")
        texpbody=$(zenity --text-info --editable --title="Test Case $i Expected Response Body (optional)" --width=600 --height=200)
        testcases_json+="{\"desc\":\"$tdesc\",\"method\":\"$tmethod\",\"url\":\"$turl\",\"headers\":\"$theaders\",\"body\":\"$tbody\",\"expected_status\":\"$tstatus\",\"expected_body\":\"$texpbody\"},"
    done
    testcases_json=${testcases_json%,}  # Remove trailing comma
    testcases_json+="]"
fi
    jq -n --arg method "$method" --arg url "$url" --arg headers "$headers" --arg body "$body" --argjson testcases "$testcases_json" '{method:$method,url:$url,headers:$headers,body:$body,testcases:$testcases}' > "$TEMPLATES_DIR/$tname.json"
    zenity --notification --text="Template '$tname.json' saved in current directory."
}

load_template() {
    tfile=$(zenity --file-selection --title="Select Template to Load" --filename="./" --file-filter="*.json") || return
    if [[ -f "$tfile" ]]; then
        # Parse JSON fields
        if ! method=$(jq -er '.method' "$tfile") || \
           ! url=$(jq -er '.url' "$tfile") || \
           ! headers=$(jq -er '.headers' "$tfile") || \
           ! body=$(jq -er '.body' "$tfile") || \
           ! testcases=$(jq -c '.testcases' "$tfile"); then
            error_exit "Failed to parse template JSON or required fields missing."
            return 1
        fi
        if [[ "$testcases" != "[]" && "$testcases" != "null" ]]; then
            run_api_testcases "$testcases"
        else
            new_request_prefilled "$method" "$url" "$headers" "$body"
        fi
    fi
}

run_api_testcases() {
    local testcases_json="$1"
    local total pass fail
    total=0; pass=0; fail=0

    if ! mapfile -t cases < <(echo "$testcases_json" | jq -c '.[]'); then
        error_exit "Failed to parse testcases from template JSON."
        return 1
    fi
    # Arrays to store actual results
    local -a actual_status_arr actual_body_arr
    for case_json in "${cases[@]}"; do
        total=$((total+1))
        desc=$(echo "$case_json" | jq -r '.desc')
        method=$(echo "$case_json" | jq -r '.method')
        url=$(echo "$case_json" | jq -r '.url')
        headers=$(echo "$case_json" | jq -r '.headers')
        body=$(echo "$case_json" | jq -r '.body')
        expected_status=$(echo "$case_json" | jq -r '.expected_status')
        expected_body=$(echo "$case_json" | jq -r '.expected_body')
        # Build curl command
        local cmd=(curl -s -w "\n__STATUS__%{http_code}__END__" -X "$method" --max-time $CURL_TIMEOUT)
        if [[ -n "$headers" ]]; then
            while IFS= read -r h; do
                h_trimmed=$(echo "$h" | xargs)
                [[ -n "$h_trimmed" ]] && cmd+=( -H "$h_trimmed" )
            done <<< "$(echo -e "$headers")"
        fi
        for dh in "${DEFAULT_HEADERS[@]}"; do
            dh_trimmed=$(echo "$dh" | xargs)
            [[ -n "$dh_trimmed" ]] && cmd+=( -H "$dh_trimmed" )
        done
        [[ -n "$auth_header" ]] && cmd+=( -H "$auth_header" )
        # Add body only if non-empty, non-whitespace, and not GET
        if [[ -n $body && $method != "GET" ]]; then cmd+=( -d "$body" ); fi
        cmd+=("$url")
        # Actually run the curl command
        resp=$("${cmd[@]}")
        curl_exit=$?
        if [[ $curl_exit -ne 0 ]]; then
            echo "ERROR: curl failed with exit code $curl_exit for test case: $desc"
        fi
        # Parse status and body
        actual_status=$(echo "$resp" | grep -oP '__STATUS__\K[0-9]+')
        actual_body=$(echo "$resp" | sed 's/__STATUS__.*//')
        # Store for summary
        actual_status_arr+=("$actual_status")
        actual_body_arr+=("$actual_body")
        # Compute status_result
        if [[ "$actual_status" == "$expected_status" ]]; then
            status_result="PASS"
        else
            status_result="FAIL"
        fi
        # Compute body_result
        if [[ -n "$expected_body" ]]; then
            actual_body_stripped=$(echo "$actual_body" | tr -d '[:space:]')
            expected_body_stripped=$(echo "$expected_body" | tr -d '[:space:]')
            if [[ "$actual_body_stripped" == "$expected_body_stripped" ]]; then
                body_result="PASS"
            else
                body_result="FAIL"
            fi
        else
            body_result="N/A"
        fi
        if [[ "$status_result" == "PASS" && ( "$body_result" == "PASS" || "$body_result" == "N/A" ) ]]; then
            pass=$((pass+1))
        else
            fail=$((fail+1))
        fi
    done
    # Build plain text summary
    local summary_txt="API Test Suite Results\n"
    summary_txt+="Run at: $(date '+%Y-%m-%d %H:%M:%S') on $(hostname) as $(whoami)\n"
    summary_txt+="Total: $total   ✅: $pass   ❌: $fail\n\n"
    for ((i=0; i<${#cases[@]}; i++)); do
        case_json="${cases[$i]}"
        desc=$(echo "$case_json" | jq -r '.desc')
        expected_status=$(echo "$case_json" | jq -r '.expected_status')
        expected_body=$(echo "$case_json" | jq -r '.expected_body')
        actual_status="${actual_status_arr[$i]}"
        actual_body="${actual_body_arr[$i]}"
        # Compute status/body
        if [[ "$actual_status" == "$expected_status" ]]; then
            status_result="PASS"
        else
            status_result="FAIL"
        fi
        # Compute body_result
        if [[ -n "$expected_body" ]]; then
            actual_body_stripped=$(echo "$actual_body" | tr -d '[:space:]')
            expected_body_stripped=$(echo "$expected_body" | tr -d '[:space:]')
            if [[ "$actual_body_stripped" == "$expected_body_stripped" ]]; then
                body_result="PASS"
            else
                body_result="FAIL"
            fi
        else
            body_result="N/A"
        fi
        if [[ "$status_result" == "PASS" && ( "$body_result" == "PASS" || "$body_result" == "N/A" ) ]]; then
            emoji="✅"
            result_txt="PASS"
        else
            emoji="❌"
            result_txt="FAIL"
        fi
        summary_txt+="$emoji [$result_txt] $desc\n"
        summary_txt+="  Expected: Status=$expected_status, Body=$expected_body\n"
        summary_txt+="  Received: Status=$actual_status, Body=$actual_body\n\n"
    done
    zenity --text-info --title="Test Suite Results" --width=900 --height=650 --filename=<(echo -e "$summary_txt")

    # Ask if user wants to save results
    if zenity --question --title="Save Results" --text="Do you want to save these results to a file?"; then
        local save_path
        save_path=$(zenity --file-selection --save --confirm-overwrite --title="Save Results As" --filename="api_test_results_$(date +%Y%m%d_%H%M%S).txt")
        if [[ -n "$save_path" ]]; then
            echo -e "$summary_txt" > "$save_path"
            zenity --info --text="Results saved to: $save_path"
        fi
    fi
}

new_request_prefilled() {
    # Confirm
    zenity --question --title="Confirm" --text="Method: $1\nURL: $2 \nHeaders: $3\nBody: $4\nProceed?" --width=400 --height=150 || return 0

    # Build the curl command 
    local cmd="curl -s -X \"$method\" --max-time $CURL_TIMEOUT"

    # Add headers 
    if [[ -n "$headers" ]]; then
        while IFS= read -r h; do
            h_trimmed=$(echo "$h" | xargs)
            [[ -n "$h_trimmed" ]] && cmd+=" -H \"$h_trimmed\""
        done <<< "$(echo -e "$headers")"
    fi

    for dh in "${DEFAULT_HEADERS[@]}"; do
        dh_trimmed=$(echo "$dh" | xargs)
        [[ -n "$dh_trimmed" ]] && cmd+=" -H \"$dh_trimmed\""
    done

    # Add authentication header if set
    if [[ -n "$auth_header" ]]; then
        cmd+=" -H \"$auth_header\""
    fi

    # Add body only if non-empty, non-whitespace, and not GET
    body_trimmed=$(echo "$body" | xargs)
    if [[ -n "$body_trimmed" && "$method" != "GET" ]]; then
        cmd+=" -d \"$body_trimmed\""
    fi

    cmd+=" \"$url\""
    echo "Full Curl Command: $cmd"

    # Execute the command
    (
        printf "Command: %s\n" "$cmd" > /tmp/curl_debug.txt
        bash -c "$cmd" > /tmp/api_resp.txt 2>/tmp/api_err.txt || echo "CURL_ERROR" > /tmp/api_resp.txt
    ) | zenity --progress --pulsate --auto-close --no-cancel --title="Sending..." --text="Please wait" --width=600 --height=350

    cat /tmp/api_resp.txt
    if grep -q "CURL_ERROR" /tmp/api_resp.txt; then
        error_exit "Failed to contact API endpoint.\n$(cat /tmp/api_err.txt)"
        return 1
    fi

    local raw status time size response
    raw=$(< /tmp/api_resp.txt)
    status=$(grep -oP '__STATUS__\K[0-9]+' /tmp/api_resp.txt)
    time=$(grep -oP '__TIME__\K[0-9.]+(?=__END__)' /tmp/api_resp.txt)
    size=$(grep -oP '__SIZE__\K[0-9]+' /tmp/api_resp.txt)
    response=${raw//__STATUS__${status}__END__/}
    response=${response//__TIME__${time}__END__/}
    response=${response//__SIZE__${size}__END__/}
    [[ -z "$status" ]] && status="N/A"
    [[ -z "$time" ]] && time="N/A"
    [[ -z "$size" ]] && size="N/A"

    # Prepare response display
    local separator="=================================================="
    local display_file="/tmp/response_display_$$.txt"
    {
        echo "Status: $status"
        echo "Time: ${time}s"
        echo "Size: ${size} bytes"
        echo "$separator"
        echo "Raw Response:"
        echo "$response"
        # is response json or not
        if command -v jq >/dev/null 2>&1 && echo "$response" | jq . >/dev/null 2>&1; then
            echo "$separator"
            echo "Pretty JSON:"
            echo "$response" | jq .
        fi
    } > "$display_file"
    zenity --text-info --title="Response ($status)" --width=700 --height=500 --filename="$display_file"
    rm -f "$display_file" /tmp/api_resp.txt /tmp/api_err.txt

    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    {
        echo "[$timestamp] $method $url"
        echo "Headers:"
        echo "${headers:-(none)}"
        echo "Body:"
        echo "${body:-(none)}"
        echo "Status: $status"
        echo "Time: $time"
        echo "Size: $size"
        echo "Response:"
        echo "$response"
        echo "---"
    } >> "$HISTORY_FILE"

    if zenity --question --title="Export Response" --text="Export response to file?" --width=400 --height=150; then
        local export_path=$(zenity --file-selection --save --confirm-overwrite --title="Save Response As")
        [[ -n "$export_path" ]] && echo "$response" > "$export_path"
    fi
}

show_history() {
    if [[ ! -f "$HISTORY_FILE" ]]; then
        zenity --info --text="No history available." && return
    fi
    zenity --text-info --title="Request History" --filename="$HISTORY_FILE" --width=800 --height=600
    # Ask if user wants to filter
    if zenity --question --title="Filter History" --text="Do you want to filter history?" --ok-label="Yes" --cancel-label="No" --width=400 --height=150; then
        filter=$(zenity --entry --title="Search History" --text="Enter keyword to filter:")
        if [[ -n $filter ]]; then
            grep -i -B3 -A3 "$filter" "$HISTORY_FILE" | zenity --text-info --title="Filtered History" --width=800 --height=600
        fi
    fi
}

manage_defaults() {
    action=$(zenity --list --title="Default Headers" --text="Choose action:" --column=Action Add Remove View --width=400 --height=200)
    case "$action" in
        Add)
            hdr=$(zenity --entry --title="Add Default Header" --text="Header (Name: Value):") || return
            echo "$hdr" >> "$DEFAULT_HEADERS_FILE"
            DEFAULT_HEADERS+=("$hdr")
            zenity --info --text="Header added."
            ;;
        Remove)
            [[ ! -f "$DEFAULT_HEADERS_FILE" ]] && zenity --info --text="No default headers." && return
            choice=$(zenity --list --title="Remove Header" --column=Header "${DEFAULT_HEADERS[@]}") || return
            grep -vFx "$choice" "$DEFAULT_HEADERS_FILE" > /tmp/tmp_hdr && mv /tmp/tmp_hdr "$DEFAULT_HEADERS_FILE"
            DEFAULT_HEADERS=(); mapfile -t DEFAULT_HEADERS < "$DEFAULT_HEADERS_FILE"
            zenity --info --text="Header removed."
            ;;
        View)
            [[ ! -f "$DEFAULT_HEADERS_FILE" ]] && zenity --info --text="No default headers." && return
            zenity --text-info --title="Default Headers" --filename="$DEFAULT_HEADERS_FILE" --width=600 --height=400
            ;;
    esac
}

clear_history() {
    if zenity --question --title="Clear History" --text="Are you sure you want to delete all history?" --ok-label=Yes --cancel-label=No; then
        > "$HISTORY_FILE"
        zenity --info --text="History cleared."
    fi
}

if [[ "$1" == "--headless" && -n "$2" ]]; then
    template_file="$2"
    if [[ ! -f "$template_file" ]]; then
        echo "Error: Template file '$template_file' not found." >&2
        exit 1
    fi
    # Parse testcases from template
    testcases=$(jq -c '.testcases' "$template_file" 2>/dev/null)
    if [[ -z "$testcases" || "$testcases" == "null" ]]; then
        echo "No testcases found in template." >&2
        exit 1
    fi
    # Run tests (headless)
    total=0; pass=0; fail=0
    mapfile -t cases < <(echo "$testcases" | jq -c '.[]')
    declare -a actual_status_arr actual_body_arr
    for case_json in "${cases[@]}"; do
        total=$((total+1))
        desc=$(echo "$case_json" | jq -r '.desc')
        method=$(echo "$case_json" | jq -r '.method')
        url=$(echo "$case_json" | jq -r '.url')
        headers=$(echo "$case_json" | jq -r '.headers')
        body=$(echo "$case_json" | jq -r '.body')
        expected_status=$(echo "$case_json" | jq -r '.expected_status')
        expected_body=$(echo "$case_json" | jq -r '.expected_body')
        local_cmd=(curl -s -w "\n__STATUS__%{http_code}__END__" -X "$method" --max-time $CURL_TIMEOUT)
        if [[ -n "$headers" ]]; then
            while IFS= read -r h; do
                h_trimmed=$(echo "$h" | xargs)
                [[ -n "$h_trimmed" ]] && local_cmd+=( -H "$h_trimmed" )
            done <<< "$(echo -e "$headers")"
        fi
        if [[ -n "$body" && $method != "GET" ]]; then local_cmd+=( -d "$body" ); fi
        local_cmd+=("$url")
        resp=$(eval "${local_cmd[@]}")
        actual_status=$(echo "$resp" | grep -oP '__STATUS__\K[0-9]+')
        actual_body=$(echo "$resp" | sed 's/__STATUS__.*//')
        actual_status_arr+=("$actual_status")
        actual_body_arr+=("$actual_body")
        if [[ "$actual_status" == "$expected_status" ]]; then
            status_result="PASS"
        else
            status_result="FAIL"
        fi
        if [[ -n "$expected_body" ]]; then
            actual_body_stripped=$(echo "$actual_body" | tr -d '[:space:]')
            expected_body_stripped=$(echo "$expected_body" | tr -d '[:space:]')
            if [[ "$actual_body_stripped" == "$expected_body_stripped" ]]; then
                body_result="PASS"
            else
                body_result="FAIL"
            fi
        else
            body_result="N/A"
        fi
        if [[ "$status_result" == "PASS" && ( "$body_result" == "PASS" || "$body_result" == "N/A" ) ]]; then
            pass=$((pass+1))
        else
            fail=$((fail+1))
        fi
    done
    # Print summary
    echo "API Test Suite Results"
    echo "Run at: $(date '+%Y-%m-%d %H:%M:%S') on $(hostname) as $(whoami)"
    echo "Total: $total   PASS: $pass   FAIL: $fail"
    echo
    for ((i=0; i<${#cases[@]}; i++)); do
        case_json="${cases[$i]}"
        desc=$(echo "$case_json" | jq -r '.desc')
        expected_status=$(echo "$case_json" | jq -r '.expected_status')
        expected_body=$(echo "$case_json" | jq -r '.expected_body')
        actual_status="${actual_status_arr[$i]}"
        actual_body="${actual_body_arr[$i]}"
        if [[ "$actual_status" == "$expected_status" ]]; then
            status_result="PASS"
        else
            status_result="FAIL"
        fi
        if [[ -n "$expected_body" ]]; then
            actual_body_stripped=$(echo "$actual_body" | tr -d '[:space:]')
            expected_body_stripped=$(echo "$expected_body" | tr -d '[:space:]')
            if [[ "$actual_body_stripped" == "$expected_body_stripped" ]]; then
                body_result="PASS"
            else
                body_result="FAIL"
            fi
        else
            body_result="N/A"
        fi
        if [[ "$status_result" == "PASS" && ( "$body_result" == "PASS" || "$body_result" == "N/A" ) ]]; then
            emoji="✅"
            result_txt="PASS"
        else
            emoji="❌"
            result_txt="FAIL"
        fi
        echo "$emoji [$result_txt] $desc"
        echo "  Expected: Status=$expected_status, Body=$expected_body"
        echo "  Received: Status=$actual_status, Body=$actual_body"
        echo
    done
    exit 0
fi

if command -v zenity >/dev/null 2>&1; then
    show_main_menu
else
    echo "Zenity not found. Please install zenity to use the GUI."
    exit 1
fi
