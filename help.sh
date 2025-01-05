#!/usr/bin/env bash

# verify ollama
if ! command -v ollama &> /dev/null; then
  echo "Error: ollama is required to run this script."
  echo "Please install ollama."
fi

# obtain vars
DEFAULT_HELP_SH_MODEL="${DEFAULT_HELP_SH_MODEL:-deepseek-coder}"
MODEL="${MODEL:-$DEFAULT_HELP_SH_MODEL}"
SYSTEM_NAME=$(uname -s)
if [[ "$SYSTEM_NAME" == "Darwin" ]]; then
  SYSTEM_NAME="macOS"
fi

# auto search models, prioritize deepseek-coder
AVAIL_MODELS="$(ollama ls | tail -n +2 | awk '{print $1}')"

MATCHING_MODELS="$(echo "$AVAIL_MODELS" | grep "$MODEL")"

PREFERRED_MODEL="$(echo "$MATCHING_MODELS" | head -n 1 | awk '{print $1}')"

# help
if [[ -z "$1" || "$1" == "-h" || "$1" == "--help" || "$1" == "help" ]]; then
  printf '\033[1m'
  echo "Usage: $(basename "$0") [instructions...]"
  printf '\033[0m'
  echo
  echo "This script uses ollama to generate a command line command based on"
  echo "given instructions. For example:"
  echo
  printf '\033[0m'
  printf "    $ "
  printf '\033[0;33m'
  printf "help list files in current directory\n"
  printf "\n"
  printf "    "
  printf '\033[0;32m'
  printf "ls\n"
  printf '\033[0;33m'
  echo
  printf "    "
  printf "Run the above command [y/N] or regenerate [r]?"
  printf '\033[0m'
  printf "\n"
  echo
  echo "Configure the MODEL environment variable to temporarily change the model used."
  echo "A partial match is sufficient - the first match in \`ollama ls\` is used."
  echo "The currently active model is '$PREFERRED_MODEL'."
  echo
  echo "Use DEFAULT_HELP_SH_MODEL to set a default model to search for."
  echo "The current default is set to search for '$DEFAULT_HELP_SH_MODEL'."
  exit 1
fi

if [[ -z "$MATCHING_MODELS" ]]; then
  echo "Error: Model '$MODEL' not found in ollama."
  exit 1
fi

# start up
printf '\n'
printf '\033[0;90m'
printf "Starting up "
printf '\033[1m'
printf "$PREFERRED_MODEL"
printf '\033[0;90m'
printf "... \n"
RESULT="$(ollama run "$PREFERRED_MODEL" "Please reply with 'Ready!'")"
RESULT=""
printf '\033[0m'

# obtain instructions
INSTRUCTIONS="$*"

# generate command with ollama + deepseek-coder:6.7b
SHELL_NAME=$(echo "$SHELL" | awk -F'/' '{print $NF}')
if [ -z "$SHELL_NAME" ]; then
  SHELL_NAME="bash"
fi

PREPROMPT="You are a personal assistant that provides CLI commands for a $SHELL_NAME shell running on $SYSTEM_NAME based on the given instructions. Your output is immediately ran on a $SHELL_NAME terminal on this system. Do NOT provide explanations. Do NOT elaborate. Your replied command will be immediately run in the terminal. You are to reply as the JSON format { success: boolean, command: string }. Please write the following task as a CLI command: "

printf '\033[0;90m'
printf "Input Task: "
printf '\033[1;90m'
printf "$INSTRUCTIONS"
printf '\033[0m'
printf '\n'


extract_codeblock() {
  RESULT="$1"
  if [[ ! -z "$RESULT" ]]; then
    # objective:
    # if surrounded with "```" remove first and last lines
    # also trim newlines at the front and back
    PATTERNSTART='^```'
    PATTERNEND='```$'

    RESULT_BAK="$RESULT"

    # trim to codeblock
    while [[ ! -z "$RESULT" ]]; do
      if [[ "$RESULT" =~ $PATTERNSTART && "$RESULT" =~ $PATTERNEND ]]; then

        RESULT=$(echo -e "$RESULT" | sed '1d')
        RESULT=$(echo -e "$RESULT" | sed '$d')
        RESULT=$(echo -e "$RESULT" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

        break;
      fi

      if [[ ! "$RESULT" =~ $PATTERNSTART ]]; then
        RESULT=$(echo -e "$RESULT" | sed '1d')
      fi

      if [[ ! "$RESULT" =~ $PATTERNEND ]]; then
        RESULT=$(echo -e "$RESULT" | sed '$d')
      fi
    done

    # if no codeblock, throw error
    if [[ -z "$RESULT" ]]; then
      printf '\n'
      printf '\033[0;31m'
      echo "Internal error: Output format not recognized."
      printf '\033[0m'

      printf '\033[0;90m'
      echo -e "$RESULT_BAK"
      printf '\033[0m'
    fi
  fi
}

while [[ ! -z "$INSTRUCTIONS" ]]; do

  # evaluate
  RAW_RESULT="$(ollama run --format json "$PREFERRED_MODEL" "$PREPROMPT '$INSTRUCTIONS'")"
  RAW_RESULT=$(echo -e "$RAW_RESULT" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

  # attempt jq parsing
  RESULT="$(echo -e "$RAW_RESULT" | jq -r '.command')"
  if [[ $? == 0 ]]; then
    SUCCESS="$(echo -e "$RAW_RESULT" | jq -r '.success')"
  else
    SUCCESS="false"
    FAIL_REASON="JSON parsing error!"
  fi

  # verify not empty
  if [[ -z "$RESULT" || "$SUCCESS" != "true" ]]; then

    printf '\n'
    printf '\033[0;31m'
    printf "Failed to generate command! "
    if [[ ! -z "$FAIL_REASON" && "$FAIL_REASON" != "null" ]]; then
      echo -e "$FAIL_REASON"
    fi
    printf '\033[0m'
    printf '\n'

    read -p "Regenerate [r]? " -n 1 -r
    if [[ $REPLY =~ ^[YyRr]$ ]]; then
      printf '\r'
      printf "Regenerating...     \n"
      continue
    fi

    printf "\nCancelling...\n\n"
    exit 1
  fi

  # confirm and run
  printf '\n'
  printf '\033[0;32m'
  echo -e "$RESULT"
  printf '\033[0m'
  printf '\n'

  # describe the command and check if it has side effects
  true && {
    printf "Interpreting..."
    VERIFICATION="$(ollama run --format json \
      "$PREFERRED_MODEL" \
      "A command is suggested to be run on this machine in the working directory of '$(pwd)'. Please determine what it does and provide a description. Also indicate it the command is destructive (cannot be undone), or if it may take a long time to run. Reply these details in JSON with the format { is_destructive: boolean, is_long_running: boolean, command_description: string }. When giving the description, keep it brief and short, but include any key details. Do not elaborate. The commands are as follows:\n$RESULT"
    )"

    IS_DESTRUCTIVE="$(echo -e "$VERIFICATION" | jq -r '.is_destructive')"
    IS_LONG_RUNNING="$(echo -e "$VERIFICATION" | jq -r '.is_long_running')"
    COMMAND_DESCRIPTION="$(echo -e "$VERIFICATION" | jq -r '.command_description')"

    if [[ "$COMMAND_DESCRIPTION" == "null" ]]; then
      COMMAND_DESCRIPTION=""
    fi

    # if long running, prompt the user about it
    if [[ "$IS_LONG_RUNNING" != "false" ]]; then
      printf '\033[1;33m'
      echo "This command may take a while to run."
      printf '\033[0m'
    fi

    # if dangerous, prompt the user about it
    if [[ "$IS_DESTRUCTIVE" != "false" ]]; then
      if [[ -z "$COMMAND_DESCRIPTION" ]]; then
        COMMAND_DESCRIPTION="Unable to evaluate if the command is dangerous. Proceed with caution. Output was: $VERIFICATION"
      fi

      if [[ "$COMMAND_DESCRIPTION" != "null" && ! -z "$COMMAND_DESCRIPTION" ]]; then
        printf '\033[1;31m'
        printf 'WARNING: '
        echo -e "$COMMAND_DESCRIPTION"
        printf '\033[0m'
      fi
    else
      printf '\033[0;90m'
      printf 'Interpretation: '
      printf '\033[1;90m'
      echo -e "$COMMAND_DESCRIPTION"
      printf '\033[0m'
    fi
  }

  false && {
    # secondary verification of interpretation (seems quite unreliable, temporarily disabled)
    printf "Validating..."
    VERIFICATION2="$(ollama run --format json \
      "$PREFERRED_MODEL" \
      "The user requested to perform the task of '$INSTRUCTIONS' inside a given working directory on a computer. An AI assistant has provided help, believing the user wants to perform: $COMMAND_DESCRIPTION. Is the assistant's interpretation of the user's request reasonable? Reply as a JSON output of { reasonable: boolean }."
    )"
    IS_CORRECT="$(echo -e "$VERIFICATION2" | jq -r '.reasonable')"

    if [[ "$IS_CORRECT" != "true" ]]; then
      printf '\033[1;31m'
      printf 'NOTE: '
      printf '\033[0;31m'
      printf "The given command may not match your intended goal. Please take caution."
      printf '\033[0m'
    fi
  }

  # prompt user
  printf '\n'
  printf "Run the above command [y/N] or regenerate [r]? "
  read -p "" -n 1 -r

  printf '\r'
  printf "                                                "
  printf '\r'

  if [[ $REPLY =~ ^[Yy]$ ]]; then
    printf "Executing...\n\n"
    eval "$RESULT"
    break
  elif [[ $REPLY =~ ^[Rr]$ ]]; then
    printf '\r'
    printf "Regenerating...\n"
    continue
  fi
  printf "Cancelling...\n\n"
  exit 0

done
