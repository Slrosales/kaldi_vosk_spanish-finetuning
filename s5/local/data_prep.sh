#!/usr/bin/env bash

# data_prep.sh para OpenSLR Spanish Datasets
# Uso: local/data_prep.sh <ruta_a_databases_txt> <directorio_descarga_corpus>

export LC_ALL=C.UTF-8

if [ "$#" -ne 2 ]; then
    echo "Uso: $0 <ruta_a_databases_txt> <directorio_descarga_corpus>"
    echo "e.g.: local/data_prep.sh local/databases.txt Corpora"
    exit 1
fi

databases_file="$1"
corpus_download_dir="$2"

# Porcentajes para la división train/dev/test
train_percent=80
dev_percent=10
test_percent=10

# Directorios de datos de Kaldi
data_dir="data"
train_dir="$data_dir/train"
dev_dir="$data_dir/dev"
test_dir="$data_dir/test"
local_dir="$data_dir/local_prep_tmp" # Archivos temporales por corpus antes de la división

# Crear directorios si no existen (mkdir -p se encarga de esto)
mkdir -p "$corpus_download_dir" "$train_dir" "$dev_dir" "$test_dir" "$local_dir"

echo "Limpiando directorios de salida y temporales de ejecuciones previas..."

for dir_to_clean in "$train_dir" "$dev_dir" "$test_dir" "$local_dir"; do
  if [ -d "$dir_to_clean" ]; then
    rm -rf "$dir_to_clean"/*
  fi
done

# --- Función de Limpieza de Texto ---

function normalize_text {
    local text_input="$1"
    echo "$text_input" | local/normalize_unicode.py

}

# --- Función para descargar archivos si es necesario ---
function download_file_if_needed {
    local base_url="$1"  # URL del recurso (e.g., https://www.openslr.org/resources/72)
    local file_name="$2" # Nombre del archivo a descargar (e.g., line_index_female.tsv)
    local dest_path="$3" # Directorio destino completo para el archivo (e.g., Corpora/slr72_colombian/line_index_female.tsv)

    if [[ -z "$file_name" ]]; then
        echo "Advertencia: Nombre de archivo vacío para descarga desde $base_url. Saltando."
        return 0
    fi

    echo "    DEBUG (download_file_if_needed): Intentando descargar '$file_name' desde '$base_url' hacia '$dest_path'"

    if [ ! -f "$dest_path" ]; then
        echo "  Descargando $base_url/$file_name hacia $dest_path ..."
        mkdir -p "$(dirname "$dest_path")"
        wget -O "$dest_path" "$base_url/$file_name" || {
            echo "Error descargando $base_url/$file_name"
            return 1 
        }
        echo "      Descarga de $file_name completada." 
    else
        echo "      Archivo $file_name ya existe en $dest_path. Saltando descarga." 
    fi
    return 0 
}

# --- Función para descomprimir archivos ZIP si es necesario ---
function extract_zip_if_needed {
    local zip_file_path="$1"  # Ruta completa al archivo ZIP
    local extract_to_dir="$2" # Directorio donde se extraerá el contenido

    echo "    DEBUG (extract_zip_if_needed): Intentando extraer '$zip_file_path' hacia '$extract_to_dir'"

    if [[ -z "$zip_file_path" ]] || [ ! -f "$zip_file_path" ]; then
        echo "Advertencia: Archivo ZIP no proporcionado o no encontrado '$zip_file_path'. Saltando extracción."
        return 0
    fi

    # Descomprimir si el directorio de extracción no existe o está vacío
    if [ ! -d "$extract_to_dir" ] || [ -z "$(ls -A "$extract_to_dir")" ]; then
        echo "  Descomprimiendo $zip_file_path en $extract_to_dir ..."
        mkdir -p "$extract_to_dir"
        unzip -q -o "$zip_file_path" -d "$extract_to_dir" || {
            echo "Error descomprimiendo $zip_file_path"
            return 1 # Indica error
        }
        echo "      Extracción de $zip_file_path completada." # DEBUG
    else
        echo "      El directorio $extract_to_dir ya existe y no está vacío. Saltando extracción." # DEBUG
    fi
    return 0 # Éxito
}

# --- Función Núcleo para procesar un archivo de índice TSV ---
function process_index_file_core {
    local tsv_file_path="$1"          # Ruta completa al archivo TSV
    local gender_tag="$2"             # 'f', 'm', o ''
    local audio_search_base_path="$3" # Directorio base donde buscar los archivos de audio (después de extraer el ZIP)
    local current_corpus_name="$4"    # Nombre del corpus (e.g., slr72_colombian)
    local speaker_id_prefix="$5"      # Prefijo para el ID de hablante (e.g., col)

    # ---- DEBUG ----
    echo "      DEBUG (process_index_file_core): Iniciando para TSV: '$tsv_file_path'"
    echo "      DEBUG (process_index_file_core): Audio Search Base Path: '$audio_search_base_path'"
    echo "      DEBUG (process_index_file_core): Género Tag: '$gender_tag', Corpus: '$current_corpus_name', Prefijo: '$speaker_id_prefix'"
    # ---- FIN DEBUG ----

    if [ ! -f "$tsv_file_path" ]; then
        echo "      Advertencia (process_index_file_core): Archivo de índice no encontrado para procesar: $tsv_file_path"
        return
    fi

    local lines_processed=0 
    local line_content

    while IFS= read -r line_content || [[ -n "$line_content" ]]; do
        if [[ -z "$line_content" ]]; then
            if [[ "$lines_processed" -gt 0 ]]; then break; else continue; fi
        fi

        lines_processed=$((lines_processed + 1))

        local audio_filename_in_tsv # Este será el stem del archivo, e.g., "cof_02436_01372133479"
        local transcript

        # Usar parameter expansion para obtener la primera palabra (nombre de archivo)
        audio_filename_in_tsv="${line_content%%[[:space:]]*}"
        # Usar parameter expansion para obtener el resto después del primer grupo de espacios (transcripción)
        transcript="${line_content#*"$audio_filename_in_tsv"}"
        # Quitar espacios al inicio de la transcripción
        transcript="${transcript#"${transcript%%[![:space:]]*}"}"

        if [[ -z "$audio_filename_in_tsv" ]] || [[ -z "$transcript" ]]; then
            echo "        Advertencia (process_index_file_core): No se pudo parsear audio o transcripción de la línea '$line_content'. Saltando."
            continue
        fi

        # --- INICIO DE SECCIÓN MODIFICADA ---
        # Basado en el formato del TSV "cof_02436_01372133479 Transcripción..."
        # audio_filename_in_tsv es ahora "cof_02436_01372133479"

        local speaker_part_from_filename   # e.g., "02436"
        local utterance_part_from_filename # e.g., "01372133479"

        # Usar cut para extraer las partes del nombre del archivo.
        # Asumimos que el delimitador es '_' y queremos la 2da y 3ra parte.
        # El primer `cut -d'_' -f2-` quita la primera parte (e.g., "cof") -> "02436_01372133479"
        # Luego, de eso, tomamos la primera parte para el hablante y la segunda para la elocución.
        local remaining_parts=$(echo "$audio_filename_in_tsv" | cut -d'_' -f2-) # -> 02436_01372133479

        speaker_part_from_filename=$(echo "$remaining_parts" | cut -d'_' -f1)   # -> 02436
        utterance_part_from_filename=$(echo "$remaining_parts" | cut -d'_' -f2) # -> 01372133479

        if [[ -z "$speaker_part_from_filename" ]] || [[ -z "$utterance_part_from_filename" ]]; then
            echo "        Advertencia (process_index_file_core): No se pudo extraer speaker_part o utterance_part de '$audio_filename_in_tsv' (remaining_parts: '$remaining_parts'). Saltando."
            continue
        fi

        # final_raw_speaker_id será la parte numérica del hablante
        local final_raw_speaker_id="$speaker_part_from_filename"

        local speaker_id="${speaker_id_prefix}_${gender_tag}_${final_raw_speaker_id}"
        speaker_id=$(echo "$speaker_id" | sed 's/__\+/_/g' | sed 's/_$//' | sed 's/^_//') # Limpiar guiones bajos

        if ! [[ " ${corpus_speakers_list[*]} " =~ " ${speaker_id} " ]]; then
            corpus_speakers_list+=("$speaker_id")
        fi

        # El nombre del archivo en disco será audio_filename_in_tsv (que es el stem) + ".wav"
        local filename_on_disk_with_wav="${audio_filename_in_tsv}.wav"

        # El utterance_id se forma con el speaker_id completo y la parte de la elocución.
        local utterance_id="${speaker_id}-${utterance_part_from_filename}" # Usar utterance_part_from_filename
        utterance_id=$(echo "$utterance_id" | tr -cd '[:alnum:]_-')        # Limpiar para Kaldi

        local normalized_transcript
        normalized_transcript=$(normalize_text "$transcript")
        if [ -z "$normalized_transcript" ]; then
            echo "        Advertencia (process_index_file_core): Transcripción vacía para '$audio_filename_in_tsv' (Utt: '$utterance_id'), saltando."
            continue
        fi

        local found_audio_path
        # Buscar el archivo de audio: primero con .wav, luego con wildcard
        found_audio_path=$(find "$audio_search_base_path" -name "$filename_on_disk_with_wav" -print -quit)
        if [ -z "$found_audio_path" ]; then
            found_audio_path=$(find "$audio_search_base_path" -name "${audio_filename_in_tsv}.*" -print -quit)
            if [ -z "$found_audio_path" ]; then
                echo "        Advertencia (process_index_file_core): Audio '${audio_filename_in_tsv}.[wav|*]' no encontrado en '$audio_search_base_path' (Utt: '$utterance_id'), saltando."
                continue
            fi
        fi

        echo "$utterance_id $normalized_transcript" >>"$local_dir/${current_corpus_name}.text"
        echo "$utterance_id sox \"$found_audio_path\" -r 16000 -b 16 -c 1 -t wav - |" >>"$local_dir/${current_corpus_name}.wav.scp"
        echo "$utterance_id $speaker_id" >>"$local_dir/${current_corpus_name}.utt2spk"
        if [[ -n "$gender_tag" ]]; then
            echo "$speaker_id $gender_tag" >>"$local_dir/${current_corpus_name}.spk2gender"
        fi
    done <"$tsv_file_path"

    if [ "$lines_processed" -eq 0 ] && [ -s "$tsv_file_path" ]; then
        echo "      ERROR CRÍTICO (process_index_file_core): No se procesó ninguna línea del TSV '$tsv_file_path' aunque el archivo tiene contenido. Revisar formato de TSV y comando read."
    elif [ "$lines_processed" -eq 0 ]; then
        echo "      DEBUG (process_index_file_core): No se procesó ninguna línea del TSV '$tsv_file_path' (archivo podría estar vacío)."
    else
        echo "      DEBUG (process_index_file_core): Se leyeron $lines_processed líneas del TSV '$tsv_file_path'."
    fi
    echo "    DEBUG (process_index_file_core): Muestra de $local_dir/${current_corpus_name}.text (primeras 5):"
    head -n 5 "$local_dir/${current_corpus_name}.text"
    echo "    DEBUG (process_index_file_core): Muestra de $local_dir/${current_corpus_name}.utt2spk (primeras 5):"
    head -n 5 "$local_dir/${current_corpus_name}.utt2spk"

    echo "      DEBUG (process_index_file_core): Finalizado. Hablantes acumulados para $current_corpus_name: ${#corpus_speakers_list[@]}"
}

# --- Función para gestionar descarga, extracción y procesamiento para un conjunto de audio (e.g., female o male) ---
function process_single_audio_set {
    local base_url="$1"
    local corpus_dataset_path="$2"   # Ruta base del corpus (e.g., Corpora/slr72_colombian)
    local index_tsv_name="$3"        # Nombre del archivo TSV (e.g., line_index_female.tsv)
    local audio_zip_name="$4"        # Nombre del archivo ZIP de audio (e.g., es_co_female.zip)
    local gender_tag_for_spk_id="$5" # 'f' o 'm'
    local current_corpus_name="$6"
    local speaker_id_prefix="$7"

    # ---- DEBUG ----
    echo "  DEBUG (process_single_audio_set): Iniciando para Corpus: '$current_corpus_name', Género: '$gender_tag_for_spk_id'"
    echo "  DEBUG (process_single_audio_set): Index TSV Name a usar: '$index_tsv_name'"
    echo "  DEBUG (process_single_audio_set): Audio ZIP Name a usar: '$audio_zip_name'"
    # ---- FIN DEBUG ----

    if [[ -z "$index_tsv_name" ]] || [[ -z "$audio_zip_name" ]]; then
        echo "  Advertencia: No se proporcionó archivo de índice o audio para ${gender_tag_for_spk_id} en $current_corpus_name. Saltando este conjunto."
        return
    fi

    echo "  Procesando conjunto para género: ${gender_tag_for_spk_id}"

    # Descargar archivo de índice
    download_file_if_needed "$base_url" "$index_tsv_name" "$corpus_dataset_path/$index_tsv_name" || return 1

    # Descargar archivo de audio ZIP
    download_file_if_needed "$base_url" "$audio_zip_name" "$corpus_dataset_path/$audio_zip_name" || return 1

    # Definir directorio de extracción para este ZIP específico
    local audio_extract_target_dir="$corpus_dataset_path/extracted_audio_$(basename "$audio_zip_name" .zip)"

    # Extraer el ZIP de audio
    extract_zip_if_needed "$corpus_dataset_path/$audio_zip_name" "$audio_extract_target_dir" || return 1

    # Procesar el archivo de índice, buscando audios en el directorio de extracción
    process_index_file_core "$corpus_dataset_path/$index_tsv_name" \
        "$gender_tag_for_spk_id" \
        "$audio_extract_target_dir" \
        "$current_corpus_name" \
        "$speaker_id_prefix"

    echo "  DEBUG (process_single_audio_set): Finalizado para Corpus: '$current_corpus_name', Género: '$gender_tag_for_spk_id'" # DEBUG
}

# --- Función Principal para Procesar una Sección del Corpus de databases.txt ---
function handle_corpus_section {
    local current_corpus_name="$1"
    # Asume que db_info es un array asociativo global con la info de la sección actual

    echo "Procesando sección de corpus: $current_corpus_name"

    local url="${db_info[url]}"
    local prefix="${db_info[prefix]}"
    local gender_type="${db_info[gender]}"
    local corpus_dataset_path="$corpus_download_dir/$current_corpus_name" 

    mkdir -p "$corpus_dataset_path"
    corpus_speakers_list=() # IMPORTANTE: Resetear la lista de hablantes para cada corpus

    echo "  URL: $url, Prefijo: $prefix, Tipo Género: $gender_type"

    if [[ "$gender_type" == "separate" ]]; then
        echo "  DEBUG (handle_corpus_section - separate - female): Index='${db_info[line_index_female]}', Audio='${db_info[audio_female]}'"
        process_single_audio_set "$url" "$corpus_dataset_path" \
            "${db_info[line_index_female]}" "${db_info[audio_female]}" \
            "f" "$current_corpus_name" "$prefix"

        echo "  DEBUG (handle_corpus_section - separate - male): Index='${db_info[line_index_male]}', Audio='${db_info[audio_male]}'"

        process_single_audio_set "$url" "$corpus_dataset_path" \
            "${db_info[line_index_male]}" "${db_info[audio_male]}" \
            "m" "$current_corpus_name" "$prefix"

    elif [[ "$gender_type" == "female_only" ]]; then
        process_single_audio_set "$url" "$corpus_dataset_path" \
            "${db_info[line_index]}" "${db_info[audio]}" \
            "f" "$current_corpus_name" "$prefix"

    elif [[ "$gender_type" == "male_only" ]]; then
        process_single_audio_set "$url" "$corpus_dataset_path" \
            "${db_info[line_index]}" "${db_info[audio]}" \
            "m" "$current_corpus_name" "$prefix"


    else
        echo "  Error: Tipo de género '$gender_type' no reconocido para $current_corpus_name."
        return 1 # Indicar error
    fi

    # --- División Train/Dev/Test por Hablante para este corpus ---
    if [ ${#corpus_speakers_list[@]} -eq 0 ]; then
        echo "  Advertencia: No se procesaron hablantes para el corpus $current_corpus_name. Saltando división."
    else
        echo "  Dividiendo ${#corpus_speakers_list[@]} hablantes de $current_corpus_name en train/dev/test..."
        local shuffled_speakers
        shuffled_speakers=($(shuf -e "${corpus_speakers_list[@]}"))

        local num_total_spk=${#shuffled_speakers[@]}
        local num_train_spk=$((num_total_spk * train_percent / 100))
        local num_dev_spk=$((num_total_spk * dev_percent / 100))

        # Ajustes para asegurar al menos 1 en dev/test si hay suficientes hablantes
        if [ "$num_total_spk" -gt 2 ]; then # Necesitas al menos 3 para tener train, dev y test
            if [ "$num_dev_spk" -eq 0 ]; then num_dev_spk=1; fi
            # Si train + dev ya es >= total, reduce train para dar espacio a test
            if [ "$((num_train_spk + num_dev_spk))" -ge "$num_total_spk" ]; then
                if [ "$num_train_spk" -gt 1 ]; then # Solo reducir train si tiene más de 1
                    num_train_spk=$((num_train_spk - 1))
                else # Si train es 1, y dev es 1, y total es 2, entonces test será 0. O dev=0
                    : 
                fi
            fi
        elif [ "$num_total_spk" -eq 2 ]; then # Si solo hay 2 hablantes
            num_train_spk=1
            num_dev_spk=1                     # O uno a test, como prefieras. Aquí dev.
        elif [ "$num_total_spk" -eq 1 ]; then # Si solo hay 1 hablante
            num_train_spk=1
            num_dev_spk=0
        fi

        local num_test_spk=$((num_total_spk - num_train_spk - num_dev_spk))
        if [ "$num_test_spk" -lt 0 ]; then num_test_spk=0; fi
        if [ "$((num_train_spk + num_dev_spk + num_test_spk))" -ne "$num_total_spk" ]; then
            num_train_spk=$((num_total_spk - num_dev_spk - num_test_spk)) # Ajustar train para cuadrar
        fi

        echo "    Asignación final - Train: $num_train_spk, Dev: $num_dev_spk, Test: $num_test_spk hablantes."

        local current_spk_idx=0
        local sets_and_counts=("$train_dir" $num_train_spk "$dev_dir" $num_dev_spk "$test_dir" $num_test_spk)
        for ((i = 0; i < ${#sets_and_counts[@]}; i += 2)); do
            local set_assignment_dir="${sets_and_counts[i]}"
            local target_count="${sets_and_counts[i + 1]}"
            if [[ "$target_count" -gt 0 ]]; then # Solo si hay hablantes que asignar a este conjunto
                for ((j = 0; j < target_count; j++)); do
                    if [[ "$current_spk_idx" -lt "$num_total_spk" ]]; then
                        local spk_to_assign="${shuffled_speakers[$current_spk_idx]}"
                        # Asignar las utterances de este hablante al conjunto correspondiente
                        grep "^${spk_to_assign}-" "$local_dir/${current_corpus_name}.text" >>"$set_assignment_dir/text"
                        grep "^${spk_to_assign}-" "$local_dir/${current_corpus_name}.wav.scp" >>"$set_assignment_dir/wav.scp"
                        grep "^${spk_to_assign}-" "$local_dir/${current_corpus_name}.utt2spk" >>"$set_assignment_dir/utt2spk"
                        current_spk_idx=$((current_spk_idx + 1))
                    else
                        break # No hay más hablantes para asignar
                    fi
                done
            fi
        done
    fi
}

# --- Bucle Principal para Procesar databases.txt ---
current_section_name=""
declare -A db_info # Array asociativo para la información de la sección actual

while IFS= read -r line || [[ -n "$line" ]]; do
    line=$(echo "$line" | tr -d '\r' | sed 's/#.*//') # Eliminar CR y comentarios
    if [[ -z "$line" ]]; then continue; fi            # Saltar líneas vacías

    if [[ "$line" =~ ^\[(.*)\]$ ]]; then # Es una nueva sección
        # Si ya había una sección siendo procesada, procésala ahora
        if [[ -n "$current_section_name" ]]; then
            handle_corpus_section "$current_section_name" # db_info es global aquí
            # Limpiar db_info para la nueva sección
            for key in "${!db_info[@]}"; do unset db_info[$key]; done
        fi
        current_section_name="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^([^=]+)=(.*)$ ]]; then # Es una línea clave=valor
        db_info["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
    fi
done <"$databases_file"

# Procesar la última sección leída del archivo (si existe)
if [[ -n "$current_section_name" ]]; then
    handle_corpus_section "$current_section_name" # db_info es global aquí
fi

# --- Finalización: Crear spk2utt y validar directorios ---
echo "Finalizando archivos globales..."
for set_dir_path in "$train_dir" "$dev_dir" "$test_dir"; do
    set_name=$(basename "$set_dir_path")
    if [ -f "$set_dir_path/utt2spk" ] && [ -s "$set_dir_path/utt2spk" ]; then # Solo si utt2spk existe y no está vacío
        echo "  Procesando conjunto final: $set_name"

        # Ordenar todos los archivos generados para consistencia y correcto funcionamiento de Kaldi
        for file_type in text wav.scp utt2spk; do
            LC_ALL=C sort -u -o "$set_dir_path/$file_type" "$set_dir_path/$file_type"
        done

        # Consolidar y filtrar spk2gender
        # Primero, juntar todos los spk2gender temporales, eliminando duplicados
        if compgen -G "$local_dir/*.spk2gender" >/dev/null; then
            cat $local_dir/*.spk2gender | LC_ALL=C sort -u >"$local_dir/all_spk2gender.tmp"
            # Luego, para cada hablante en el conjunto actual (train, dev, test), tomar su género si existe
            awk '{print $2}' "$set_dir_path/utt2spk" | LC_ALL=C sort -u | while read spk; do
                grep "^${spk} " "$local_dir/all_spk2gender.tmp" || : # El : es para evitar error si grep no encuentra nada
            done >"$set_dir_path/spk2gender"
            # Si spk2gender queda vacío después del filtrado, eliminarlo
            if [ ! -s "$set_dir_path/spk2gender" ]; then rm -f "$set_dir_path/spk2gender"; fi
        fi

        echo "  Corrigiendo y validando directorio de datos $set_name..."
        utt2spk_to_spk2utt.pl "$set_dir_path/utt2spk" >"$set_dir_path/spk2utt" 
        fix_data_dir.sh "$set_dir_path"                                        

        # AÑADE --no-feats AQUÍ:
        validate_data_dir.sh --no-feats "$set_dir_path" || { 
            echo "Error validando $set_dir_path"
            exit 1
        }
    else
        echo "  Advertencia: No se generaron datos para el conjunto $set_name o utt2spk está vacío."
    fi
done

echo "Preparación de datos completada."
echo "Directorios de datos generados en: $train_dir, $dev_dir, $test_dir"
