#!/bin/bash

source lmog.config

# variable initialization section
ORDER=0
CLEAR=false
QUERY=false
GENERATE_TABLE=false
MODELS=()
QUERY_SETTINGS=()

# Prints the usage of the script in case of using the help command.
function printUsage {
  echo 'LMOG (language model overview generator)'
  echo 'Creates language models using different language model toolkits and generates an overview table with some statistics - in order to derive their correctness.'
  echo
  echo 'Usage: ./lmog.sh [OPTIONS] CORPUS'
  echo
  echo 'LMOG uses a corpus to create language models using different toolkits.'
  echo 'Optionally these models are queried with every sequence that is possible with the corpus vocabulary.'
  echo 'LMOG then generates an overview table that shows some statistics for each toolkit:'
  echo '* the sum of all probabilities'
  echo
  echo 'All the files generated will be in '"'overview/<CORPUS>/'"'.'
  echo
  echo 'Options:'
  echo '-h, --help    Displays this help message.'
  echo '-n, --order   The order of the n-gram models that should be created.'
  echo '              (defaults to 2)'
  echo '-q, --query   Query the language models.'
  echo 'Other Options:'
  echo '-c, --clear   Clear the output directory. Everything LMOG needs to operate will be recreated automatically betimes.'
  echo '-t, --table   Generate an overview table. This option will be set automatically, if you query the language models using the option '"'-q' or '--query'"'.'
}

# Parses the startup arguments into variables.
function parseArguments {
  while [[ $# > 0 ]]; do
    key="$1"
    case $key in
      # help
      -h|--help)
      printUsage
      exit 0
      ;;
      # order
      -n|--order)
      shift
      ORDER="$1"
      ;;
      # query the language models
      # * create model binaries if not existing
      # * create query files if not existing
      # * query the models
      -q|--query)
      QUERY=true
      GENERATE_TABLE=true
      ;;
      # clear output data of current corpus
      -c|--clear)
      CLEAR=true
      ;;
      # generate an overview table
      -t|--table)
      GENERATE_TABLE=true
      ;;
      # unknown option
      -*)
      echo 'Unknown option '"'$key'"'!'
      return 1
      ;;
      # parameter
      *)
      if ! handleParameter "$1"; then
        echo 'Too many arguments!'
        return 1
      fi
      ;;
    esac
    shift
  done

  # check for valid parameters
  if [ -z "$CORPUS" ]; then
    echo '[ERROR] Too few arguments! Please provide a corpus file.'
    return 1
  elif [ ! -f "$CORPUS" ]; then
    echo '[ERROR] There is no such corpus file '"'$CORPUS'"'!'
    return 2
  fi
  
  if [ "$ORDER" -eq "0" ]; then
    ORDER=2
    echo '[INFO] Using default order n = 2.'
  fi
}

# Handles the parameters (arguments that aren't an option) and checks if their count is valid.
function handleParameter {
  # 1. corpus file
  if [ -z "$CORPUS" ]; then
    CORPUS="$1"
  else
    return 1
  fi
  
  # too many parameters
  return 0
}

# main script function section

# Generates a suffix for the current query settings.
function get_query_settings_suffix {
  local SEOS=false
  local UNK=false
  local NUM_OOV=0
  while [[ $# > 0 ]]; do
    key="$1"
    case $key in
      # seos
      -seos)
        SEOS=true
        ;;
      # unknown words
      -unk)
        UNK=true
        ;;
      # out-of-vocabulary words
      -oov)
        NUM_OOV="$2"
        shift
        ;;
    esac
    shift
  done
  
  SUFFIX=
  if $SEOS; then
    SUFFIX="$SUFFIX"'seos_'
  fi
  if $UNK; then
    SUFFIX="$SUFFIX"'unk_'
  fi
  if [ "$NUM_OOV" -ne "0" ]; then
    SUFFIX="$SUFFIX"'oov_'
  fi
  
  if [ ! -z "$SUFFIX" ]; then
    echo "$SUFFIX"
  fi
}

# Generates an out-of-words vocabulary.
function add_oov {
  local VOCAB="$1"
  local MAX_OOV="$2"
  local DESTINATION="$3"
  if [ "$MAX_OOV" -eq "0" ]; then
    return 0
  fi
  
  local OOV=()
  local NUM_OOV=0
  while read line; do
    local WORD="$line"_glmtk
    if ! grep -e "$WORD" "$VOCAB" >/dev/null; then
      OOV+=("$WORD")
      let NUM_OOV=NUM_OOV+1
    fi
    
    if [ "$NUM_OOV" -ge "$MAX_OOV" ]; then
      break
    fi
  done <"$VOCAB"
  
  cp "$VOCAB" "$DESTINATION"
  for WORD in "${OOV[@]}"; do
    echo "$WORD" >> "$DESTINATION"
  done
  echo '[INFO] Vocabulary has been expanded by '"$NUM_OOV"' OOV words.'
}

# Creates a vocabulary according to the query settings passed.
function create_vocabulary {
  local VOCAB_PLAIN="$1"
  local VOCAB_PATH="$2"
  shift
  shift
  local VOCAB_TMP="$WORKING_DIR"/vocabulary.txt.tmp
  
  local SEOS=false
  local UNK=false
  local NUM_OOV=0
  while [[ $# > 0 ]]; do
    key="$1"
    case $key in
      # seos
      -seos)
        SEOS=true
        ;;
      # unknown words
      -unk)
        UNK=true
        ;;
      # out-of-vocabulary words
      -oov)
        NUM_OOV="$2"
        shift
        ;;
    esac
    shift
  done
  
  OPT_GREP='-v -e -pau-'
  if ! $SEOS; then
    OPT_GREP="$OPT_GREP"' -e <s> -e </s>'
  fi
  if ! $UNK; then
    OPT_GREP="$OPT_GREP"' -e <unk>'
  fi
  grep $OPT_GREP "$VOCAB_PLAIN" > "$VOCAB_TMP"
  
  if [ "$NUM_OOV" -eq "0" ]; then
    mv "$VOCAB_TMP" "$VOCAB_PATH"
  else
    add_oov "$VOCAB_TMP" "$NUM_OOV" "$VOCAB_PATH"
  fi
}

# Creates missing vocabulary files.
function create_vocabularies {
  local VOCAB_PLAIN="$WORKING_DIR"/"vocabulary-plain.txt"
  "$SRILM"/ngram-count -order "$ORDER" -write-vocab "$VOCAB_PLAIN" -text "$CORPUS"
  
  for ((i = 0; i < ${#QUERY_SETTINGS[@]}; i++)); do
    local PARAMS=${QUERY_SETTINGS[$i]}
    echo 'creating vocabulary for: '"'$PARAMS'"
    local VOCAB_SUFFIX=$( get_query_settings_suffix $PARAMS )
    local VOCAB_NAME='vocabulary.txt'
    if [ ! -z "$VOCAB_SUFFIX" ]; then
      VOCAB_NAME="$VOCAB_SUFFIX"'vocabulary.txt'
    fi
    local VOCAB_PATH="$DIR"/"$VOCAB_NAME"
    echo 'vocabulary will be placed at '"'$VOCAB_PATH'"
    
    if [ ! -f "$VOCAB_PATH" ]; then
      echo create_vocabulary "$VOCAB_PLAIN" "$VOCAB_PATH" $PARAMS
      create_vocabulary "$VOCAB_PLAIN" "$VOCAB_PATH" $PARAMS
    fi
  done
}

# Adds a query setting to the LMOG processing queue.
function add_query_setting {
  local PARAMS="$@"
  QUERY_SETTINGS+=( "$PARAMS" )
}

# Adds all the query settings to the LMOG processing queue.
function add_query_settings {
  add_query_setting
  add_query_setting -seos
  add_query_setting -seos -unk
  add_query_setting -seos -unk -oov 10
  add_query_setting -unk
  add_query_setting -unk -oov 10
  add_query_setting -oov 10
}

# Adds a model to the LMOG processing queue.
function add_model {
  local PARAMS="$@"
  MODELS+=( "$PARAMS" )
}

# Adds all the models to the LMOG processing queue.
# Add new language models by adding an entry using the tool and the parameters here!
function add_models {
  # KenLM
  #add_model kenlm -i -mkn
  # KyLM
  #add_model kylm -seos -i 
  #add_model kylm -seos -i -kn
  #add_model kylm -seos -i -mkn
  # SRILM
  ## non-seos
  ### non-unk
  add_model srilm
  add_model srilm -cdiscount 0.75 -i
  add_model srilm -kn
  add_model srilm -cdiscount 0.75 -kn -i
  add_model srilm -i -kn
  add_model srilm -i -mkn
  ### with unk
  add_model srilm -unk
  add_model srilm -cdiscount 0.75 -i -unk
  add_model srilm -kn -unk
  add_model srilm -cdiscount 0.75 -kn -i -unk
  add_model srilm -i -kn -unk
  add_model srilm -i -mkn -unk
  ## with seos
  ### non-unk
  add_model srilm -seos
  add_model srilm -seos -cdiscount 0.75 -i
  add_model srilm -seos -kn
  add_model srilm -seos -cdiscount 0.75 -kn -i
  add_model srilm -seos -i -kn
  add_model srilm -seos -i -mkn
  ### with unk
  add_model srilm -seos -unk
  add_model srilm -seos -cdiscount 0.75 -i -unk
  add_model srilm -seos -kn -unk
  add_model srilm -seos -cdiscount 0.75 -kn -i -unk
  add_model srilm -seos -i -kn -unk
  add_model srilm -seos -i -mkn -unk
}

# Generates the model name depending on the parameters used to create it.
function get_model_name {
  local TOOL="$1"
  shift
  local ESTIMATOR=mle
  local INTERPOLATE=false
  local CDISCOUNT=0
  local UNK=false
  local SEOS=false
  while [[ $# > 0 ]]; do
    key="$1"
    case $key in
      # Kneser-Ney smoothing
      -kn)
        ESTIMATOR=kn
        ;;
      # Modified Kneser-Ney smoothing
      -mkn)
        ESTIMATOR=mkn
        ;;
      # interpolate
      -i)
        INTERPOLATE=true
        ;;
      # absolute discounting
      -cdiscount)
        CDISCOUNT="$2"
        shift
        ;;
      # unknown words
      -unk)
        UNK=true
        ;;
      # start-/end-of-sentence tokens
      -seos)
        SEOS=true
        ;;
    esac
    shift
  done
  
  local FILENAME="$TOOL"_"$ESTIMATOR"
  if $INTERPOLATE; then
    FILENAME="$FILENAME"_interpolated
  fi
  if [ ! "$CDISCOUNT" = "0" ]; then
    FILENAME="$FILENAME"_cdis-"$CDISCOUNT"
  fi
  if $UNK; then
    FILENAME="$FILENAME"_unk
  fi
  if $SEOS; then
    FILENAME="$FILENAME"_seos
  fi
  FILENAME="$FILENAME"-"$ORDER"
  
  QSUFF=$( get_query_settings_suffix )
  if [ ! -z "$QSUFF" ]; then
    FILENAME="$QSUFF""$FILENAME"
  fi
  
  echo "$FILENAME"
}

# Creates the language models that are missing.
function create_models {
  for ((i = 0; i < ${#MODELS[@]}; i++)); do
    local PARAMS=${MODELS[$i]}
    local MODEL_NAME=$( get_model_name $PARAMS )
    local MODEL_PATH="$DIR_LM"/"$MODEL_NAME".arpa
    
    if [ ! -f "$MODEL_PATH" ]; then
      "$ULMA"/ulma.sh -t $PARAMS -n "$ORDER" "$CORPUS" "$MODEL_PATH"
    fi
  done
}

# Creates the query files for KenLM (mandatory as other depend on it) and SRILM.
function create_query_files {
  local VOCAB_PATH="$1"
  local SUFFIX="$2"
  local CRR="$WORKING_DIR"/kenlm-query
  local NEXT="$TMP".tmp
  if [ ! -z "$SUFFIX" ]; then
    QRY_KENLM="$DIR_QREQ"/kenlm_"${SUFFIX::-1}"-"$ORDER".txt
    QRY_SRILM="$DIR_QREQ"/srilm_"${SUFFIX::-1}"-"$ORDER".txt
  else
    QRY_KENLM="$DIR_QREQ"/kenlm-"$ORDER".txt
    QRY_SRILM="$DIR_QREQ"/srilm-"$ORDER".txt
  fi
  echo "QRY_KENLM: $QRY_KENLM"
  echo "QRY_SRILM: $QRY_SRILM"
  
  # abort if all query files existing
  if [ -f "$QRY_KENLM" ] && [ -f "$QRY_SRILM" ]; then
    echo 'query files exist.'
    return 0
  fi

  # clear query file
  if [ -a "$CRR" ]; then
    >"$CRR"
  fi
  
  # create KenLM query file (basis)
  i=1
  while [ "$i" -le "$ORDER" ]; do
    if [ "$i" -eq "1" ]; then
      echo 'Step 1/'"$ORDER"': Use the vocabulary as query file basis.'
    else
      echo 'Step '"$i"'/'"$ORDER"': Expand query file by vocabulary.'
    fi
    
    if [ -a "$NEXT" ]; then
      >"$NEXT"
    else
      touch "$NEXT"
    fi
    
    if [ ! -s "$CRR" ]; then
      cp "$VOCAB_FILE" "$NEXT"
    else
      while read line; do
        awk '{print $0" '"$line"'"}' "$CRR" >> "$NEXT"
      done <"$VOCAB_FILE"
    fi
    
    mv "$NEXT" "$CRR"
    let i=i+1
  done
  
  # create SRILM query file and copy files from working dir to destinations
  echo 'finishing SRILM query file...'
  awk '{print $0" 1"}' "$CRR" > "$QRY_SRILM"
  mv "$CRR" "$QRY_KENLM"
}

# Queries a language model using KenLM.
function query_kenlm {
  local MODEL="$1"
  local RESULT="$2"
  local SEOS=false
  if [ ! -z "$3" ]; then
    SEOS=true
  fi
  
  if ! $SEOS; then
    "$KENLM"/query -n "$MODEL" <"$QRY_KENLM" > "$RESULT"
  else
    "$KENLM"/query "$MODEL" <"$QRY_KENLM" > "$RESULT"
  fi
}

# Queries a language model using SRILM.
function query_srilm {
  local MODEL="$1"
  local RESULT="$2"
  
  #"$SRILM"/ngram -lm "$MODEL" -counts "$QRY_SRILM" -debug 2 > "$RESULT"
  "$SRILM"/ngram -lm "$MODEL" -ppl "$QRY_KENLM" -debug 2 > "$RESULT"
}

# Queries all the language models with all query setting combinations.
function query {
  local SUFFIX="$1"
  for ((i = 0; i < ${#MODELS[@]}; i++)); do
    local PARAMS=${MODELS[$i]}
    local MODEL_NAME=$( get_model_name $PARAMS )
    local MODEL_PATH="$DIR_LM"/"$MODEL_NAME".arpa
    if [ -z "$SUFFIX" ]; then
      local QUERY_PATH="$DIR_QRES"/"$MODEL_NAME".txt
    else
      local QUERY_PATH="$DIR_QRES"/"$SUFFIX""$MODEL_NAME".txt
    fi

    # skip existing query results
    if [ -f "$QUERY_PATH" ]; then
      continue
    fi
    # skip missing models
    if [ ! -f "$MODEL_PATH" ]; then
      echo '[Warning] Skipping missing language model '"'$PARAMS'"'.'
      continue
    fi
    
    #TODO WTF is there a better way to access the tool name?
    for PARAM in ${PARAMS[@]}; do
      if [ "$PARAM" = "srilm" ]; then
        # SRILM
        query_srilm "$MODEL_PATH" "$QUERY_PATH"
      elif [ "$PARAM" = "kenlm" ]; then
        # KenLM
        ## generate binary file for faster queries
        local KENLM_MODEL_PATH="$DIR_LM"/"$MODEL_NAME".bin
        if [ ! -f "$KENLM_MODEL_PATH" ]; then
          "$KENLM"/build_binary "$MODEL_PATH" "$KENLM_MODEL_PATH"
        fi
        
        #TODO not THAT nice
        ## non-seos
        query_kenlm "$KENLM_MODEL_PATH" "$QUERY_PATH"
        ## with seos
        QUERY_PATH_SEOS="$DIR_QRES"/"$MODEL_NAME"_seos.txt
        query_kenlm "$KENLM_MODEL_PATH" "$QUERY_PATH_SEOS" seos
      else
        # KyLM
        echo 'KyLM querying is not implemented yet.'
      fi
      
      break
    done
  done
}

# Calculates sum(p) in the SRILM query results.
function srilm_sump {
  local RESULT="$1"
  local COLUMN=6
  let COLUMN=COLUMN+"$ORDER"
  
  local SUMP=$( head -n -5 "$RESULT" | awk '{p=p+($'"$COLUMN"')} END{print p}' )
  echo "$SUMP"
}

# Extracts the perplexity from the SRILM query results.
function srilm_ppl {
  local RESULT="$1"
  
  local PPL=$( tail -n 2 "$RESULT" | awk 'BEGIN{ORS=", "} {for (i=1;i<=NF;i++) {if ($i ~ /ppl/) {print $i$(i+1)}}}' )
  if [ "${#PPL}" -gt "2" ]; then
    echo "${PPL::-2}"
  else
    echo "$PPL"
  fi
}

# Calculates sum(p) in the KenLM query results.
function kenlm_sump {
  local RESULT="$1"
  local COLUMN=6
  let COLUMN=COLUMN+"$ORDER"
  
  local SUMP=$( head -n -7 "$RESULT" | awk '{p=p+(10 ^ $'"$COLUMN"')} END{print p}' )
  echo "$SUMP"
}

# Adds a markdown table line, generated from an array of columns.
function add_table_line {
  local TABLE="$1"
  declare -a cols=("${!2}")
  local L_LINE='|'
  for col in "${cols[@]}"; do
    L_LINE="$L_LINE"' '"$col"' |'
  done
  echo "$L_LINE" >> "$TABLE"
}

# Generates an overview table using the query result files.
function create_table {
  local TABLE="$1"
  local SUFFIX="$2"
  
  local LAST_TOOL=
  for ((i = 0; i < ${#MODELS[@]}; i++)); do
    local PARAMS=${MODELS[$i]}
    local MODEL_NAME=$( get_model_name $PARAMS )
    if [ -z "$SUFFIX" ]; then
      local QUERY_PATH="$DIR_QRES"/"$MODEL_NAME".txt
    else
      local QUERY_PATH="$DIR_QRES"/"$SUFFIX""$MODEL_NAME".txt
    fi
    
    #TODO WTF is there a better way to access the tool name?
    for PARAM in ${PARAMS[@]}; do
      local TOOL="$PARAM"
      if [ ! "$LAST_TOOL" = "$TOOL" ]; then
        # finish current table
        if [ ! -z "$LAST_TOOL" ]; then
          echo >> "$TABLE"
        fi
        
        # start new table
        echo '# '"$TOOL" >> "$TABLE"
        echo '| Model params | Querying params | Sum P(w|h) | Perplexity |' >> "$TABLE"
        echo '| ------------ | --------------- | ---------- | ---------- |' >> "$TABLE"
        LAST_TOOL="$TOOL"
      fi
      
      local line=()
      local p=TODO
      local ppl=TODO
      
      # skip missing query results
      if [ ! -f "$QUERY_PATH" ]; then
        p=n/a
        ppl=n/a
      else
        if [ "$TOOL" = "srilm" ]; then
          # SRILM
          p=$( srilm_sump "$QUERY_PATH" )
          ppl=$( srilm_ppl "$QUERY_PATH" )
        elif [ "$TOOL" = "kenlm" ]; then
          # KenLM
          p=$( kenlm_sump "$QUERY_PATH" )
        fi
      fi
      
      line+=("$PARAMS")
      line+=("$SUFFIX")
      line+=("$p")
      line+=("$ppl")
      
      add_table_line "$TABLE" line[@]
      break
    done
  done
  
  echo '' >> "$TABLE"
  echo '## Legend' >> "$TABLE"
  echo 'seos: with start-/end-of-sentence tags enabled' >> "$TABLE"
}

function produce {
  for ((j = 0; j < ${#QUERY_SETTINGS[@]}; j++)); do
    local PARAMS=${QUERY_SETTINGS[$j]}
    local SUFFIX=$( get_query_settings_suffix $PARAMS )
    local VOCAB_NAME='vocabulary.txt'
    if [ ! -z "$SUFFIX" ]; then
      VOCAB_NAME="$SUFFIX"'vocabulary.txt'
    fi
    local VOCAB_PATH="$DIR"/"$VOCAB_NAME"
    local TABLE="$DIR"/table"$SUFFIX"-"$ORDER".md
    
    VOCAB_FILE="$VOCAB_PATH"
    echo '[PHASE] producing for query settings '"'$PARAMS'"'...'
    
    if $QUERY; then
      # create missing query files
      echo '[PHASE] generate missing query files...'
      create_query_files "$VOCAB_PATH" "$SUFFIX"
      
      # query the language models
      echo '[PHASE] querying language models...'
      query "$SUFFIX"
    fi
    
    # generate the overview table
    if $GENERATE_TABLE; then
      echo '[PHASE] generating overview tables...'
      create_table "$TABLE" "$SUFFIX"
    fi
  done
}


# entry point
parseArguments "$@"
SUCCESS=$?
if [ "$SUCCESS" -ne 0 ]; then
  echo 'Use the '"'-h'"' switch for help.'
  exit "$SUCCESS"
fi

# execute main script functions
DIR="$OUTPUT_DIR"/"${CORPUS##*/}"
DIR_LM="$DIR"/lm
DIR_QREQ="$DIR"/query/request
DIR_QRES="$DIR"/query/result
VOCAB_FILE_FULL="$DIR"/vocabulary.txt
VOCAB_FILE_SEOS="$DIR"/vocabulary_seos.txt
VOCAB_FILE_UNK="$DIR"/vocabulary_unk.txt
VOCAB_FILE_CLEAN="$DIR"/vocabulary_clean.txt
VOCAB_FILE_OOV="$DIR"/vocabulary_oov.txt

QRY_KENLM="$DIR_QREQ"/kenlm-"$ORDER".txt
QRY_SRILM="$DIR_QREQ"/srilm-"$ORDER".txt

# clear output directory
if $CLEAR; then
  rm -rf "$DIR"
  echo '[INFO] Output directory has been cleared.'
fi
# build output directory structure if necessary
if [ ! -d "$DIR_LM" ]; then
  mkdir -p "$DIR_LM"
fi
if [ ! -d "$DIR_QREQ" ]; then
  mkdir -p "$DIR_QREQ"
fi
if [ ! -d "$DIR_QRES" ]; then
  mkdir -p "$DIR_QRES"
fi

add_query_settings
add_models

# create missing vocabulary files
create_vocabularies

# create missing language models
echo '[PHASE] generate missing language models...'
create_models

# query with different query files, write to respective result files and generate tables
produce
    
echo '[INFO] Done. You can find the generated files in the output directory '"'$OUTPUT_DIR'"'.'

