# --- PASO 0: Definir Variables de Ruta (ajusta si es necesario) ---

# Directorio raíz de la receta actual
RECIPE_DIR="$PWD" 

# Directorio del modelo TDNN afinado
MODEL_DIR_FINAL_TDNN="$RECIPE_DIR/exp/chain_vosk_ft/tdnn_1a"

# Directorio del árbol de cadena
TREE_CHAIN_DIR="$RECIPE_DIR/exp/chain_vosk_ft/tree_chain"

# Directorio del extractor de i-vectors
IVECTOR_EXTRACTOR_DIR="$RECIPE_DIR/exp/chain_vosk_ft/extractor"

# Directorio Lang base (contiene phones.txt, L.fst, etc. originales)
LANG_DIR_BASE="$RECIPE_DIR/data/lang"

# Directorio Lang con tu G.fst (modelo de lenguaje)
LANG_DIR_WITH_G="$RECIPE_DIR/data/lang_test_tg"

# Directorio de salida para el modelo empaquetado (en tu home de WSL)
PACKAGED_MODEL_DIR_WSL="$HOME/mi_modelo_vosk_final_wsl"

# --- PASO 1: Crear Estructura de Directorios para el Modelo Empaquetado ---
echo "Creando estructura de directorios en $PACKAGED_MODEL_DIR_WSL..."
mkdir -p "$PACKAGED_MODEL_DIR_WSL/am"
mkdir -p "$PACKAGED_MODEL_DIR_WSL/conf"
mkdir -p "$PACKAGED_MODEL_DIR_WSL/graph/phones" # graph/phones es importante
mkdir -p "$PACKAGED_MODEL_DIR_WSL/ivector"
echo "Estructura creada."

# --- PASO 2: Copiar Modelo Acústico y Árbol ---
echo "Copiando modelo acústico y árbol..."
cp "$MODEL_DIR_FINAL_TDNN/final.mdl" "$PACKAGED_MODEL_DIR_WSL/am/final.mdl" || { echo "Error copiando final.mdl"; exit 1; }
cp "$TREE_CHAIN_DIR/tree" "$PACKAGED_MODEL_DIR_WSL/am/tree" || { echo "Error copiando tree"; exit 1; }
echo "Modelo acústico y árbol copiados."

# --- PASO 3: Copiar Archivos de Configuración de Características ---
echo "Copiando configuración de MFCC..."
cp "$RECIPE_DIR/conf/mfcc.conf" "$PACKAGED_MODEL_DIR_WSL/conf/mfcc.conf" || { echo "Error copiando mfcc.conf"; exit 1; }

# Crear model.conf con parámetros de decodificación y endpointing
echo "Creando conf/model.conf..."
# Obtén los IDs de los teléfonos de silencio de tu data/lang/phones.txt
SILENCE_PHONE_IDS=$(awk '/^sil\s/{print $2} /^spn\s/{print $2}' "$LANG_DIR_BASE/phones.txt" | paste -sd: -)
if [ -z "$SILENCE_PHONE_IDS" ]; then
    echo "ADVERTENCIA: No se pudieron obtener IDs para 'sil' o 'spn' de $LANG_DIR_BASE/phones.txt. Usando valores por defecto 1:2."
    SILENCE_PHONE_IDS="1:2" # Fallback
fi
echo "  IDs de teléfonos de silencio para endpointing: $SILENCE_PHONE_IDS"

cat <<EOF > "$PACKAGED_MODEL_DIR_WSL/conf/model.conf"
--min-active=200
--max-active=4000
--beam=11.0
--lattice-beam=4.0
--acoustic-scale=1.0
--frame-subsampling-factor=3
--endpoint.silence-phones=${SILENCE_PHONE_IDS}
--endpoint.rule2.min-trailing-silence=0.5
--endpoint.rule3.min-trailing-silence=1.0
--endpoint.rule4.min-trailing-silence=2.0
EOF
echo "conf/model.conf creado."

# --- PASO 4: Copiar Componentes del Grafo de Decodificación ---
GRAPH_SOURCE_DIR="$MODEL_DIR_FINAL_TDNN/graph_tg"

echo "Copiando componentes del grafo desde $GRAPH_SOURCE_DIR..."
if [ ! -d "$GRAPH_SOURCE_DIR" ] || [ ! -f "$GRAPH_SOURCE_DIR/HCLG.fst" ]; then
    echo "Error: Directorio de grafo $GRAPH_SOURCE_DIR o HCLG.fst no encontrado. ¿Se ejecutó mkgraph.sh?"
    exit 1
fi
cp "$GRAPH_SOURCE_DIR/HCLG.fst" "$PACKAGED_MODEL_DIR_WSL/graph/HCLG.fst" || exit 1
cp "$GRAPH_SOURCE_DIR/words.txt" "$PACKAGED_MODEL_DIR_WSL/graph/words.txt" || exit 1

# Copiar el directorio phones ENTERO del grafo
if [ -d "$GRAPH_SOURCE_DIR/phones" ]; then
    cp -r "$GRAPH_SOURCE_DIR/phones/"* "$PACKAGED_MODEL_DIR_WSL/graph/phones/" || exit 1
else
    echo "ADVERTENCIA: Directorio $GRAPH_SOURCE_DIR/phones no encontrado. Copiando desde $LANG_DIR_BASE/phones."
    # Fallback a copiar desde data/lang/phones si no está en el directorio del grafo
    cp -r "$LANG_DIR_BASE/phones/"* "$PACKAGED_MODEL_DIR_WSL/graph/phones/" || exit 1
fi

if [ -f "$LANG_DIR_WITH_G/G.fst" ]; then
    cp "$LANG_DIR_WITH_G/G.fst" "$PACKAGED_MODEL_DIR_WSL/graph/Gr.fst" || echo "Advertencia: No se pudo copiar G.fst como Gr.fst"
else
    echo "Advertencia: $LANG_DIR_WITH_G/G.fst no encontrado, no se copiará Gr.fst."
fi
echo "Componentes del grafo copiados."


# --- PASO 5: Copiar Archivos del Extractor de i-vectors ---
echo "Copiando archivos del extractor de i-vectors desde $IVECTOR_EXTRACTOR_DIR..."
if [ ! -d "$IVECTOR_EXTRACTOR_DIR" ] || [ ! -f "$IVECTOR_EXTRACTOR_DIR/final.ie" ]; then
    echo "Error: Directorio de extractor de i-vectors $IVECTOR_EXTRACTOR_DIR o final.ie no encontrado."
    exit 1
fi
cp "$IVECTOR_EXTRACTOR_DIR/final.ie" "$PACKAGED_MODEL_DIR_WSL/ivector/final.ie" || exit 1

# Copiar archivos de configuración del extractor
for conf_file in online_cmvn.conf splice.conf splice_opts global_cmvn.stats final.dubm final.mat; do
    if [ -f "$IVECTOR_EXTRACTOR_DIR/$conf_file" ]; then
        cp "$IVECTOR_EXTRACTOR_DIR/$conf_file" "$PACKAGED_MODEL_DIR_WSL/ivector/" || echo "Advertencia: Falló al copiar $IVECTOR_EXTRACTOR_DIR/$conf_file"
    else
        echo "INFO: Archivo $conf_file no encontrado en $IVECTOR_EXTRACTOR_DIR, no se copiará."
    fi
done
echo "Archivos del extractor de i-vectors copiados."

# --- PASO 6: (Opcional) Archivos Adicionales y Limpieza ---
echo "Añadiendo README y LICENSE (ejemplos)..."
echo "Modelo Vosk en Español Afinado por Draken" > "$PACKAGED_MODEL_DIR_WSL/README.md"
echo "Usar bajo los términos de la licencia de los datos y modelos originales." > "$PACKAGED_MODEL_DIR_WSL/LICENSE"

echo "Empaquetado preliminar completado en: $PACKAGED_MODEL_DIR_WSL"
echo "Revisa la estructura y el contenido."

# --- PASO 7: Crear Archivo ZIP (Opcional) ---
echo "Creando archivo ZIP..."
cd "$(dirname "$PACKAGED_MODEL_DIR_WSL")" || exit 1 # Ir al directorio padre
zip -qr "$(basename "$PACKAGED_MODEL_DIR_WSL").zip" "$(basename "$PACKAGED_MODEL_DIR_WSL")/" || \
    { echo "Error creando el archivo ZIP."; cd "$RECIPE_DIR"; exit 1; }
cd "$RECIPE_DIR" # Volver al directorio original de la receta
echo "Archivo ZIP creado en: $(dirname "$PACKAGED_MODEL_DIR_WSL")/$(basename "$PACKAGED_MODEL_DIR_WSL").zip"

echo "¡EMPAQUETADO COMPLETADO!"