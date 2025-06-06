#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import epitran
import unicodedata
import re
import sys

# --- NORMALIZACIÓN PARA LA PRIMERA COLUMNA DEL LEXICÓN DE KALDI ---
def normalize_word_for_kaldi_lexicon(text_orig):
    # ... (tu función normalize_word_for_kaldi_lexicon sin cambios) ...
    text = text_orig.upper().strip()
    text = text.replace('/', ' ') 
    text = text.replace('&', ' Y ') 
    text = text.replace('-', ' ') 

    text_nfd = unicodedata.normalize('NFD', text)
    text_no_diacritics = ''.join(c for c in text_nfd if unicodedata.category(c) != 'Mn')
    
    text_no_diacritics = text_no_diacritics.replace('Ñ', 'N')
    text_no_diacritics = text_no_diacritics.replace('Ü', 'U')
    
    processed_text = re.sub(r'[^A-Z0-9N ]', '', text_no_diacritics)
    processed_text = re.sub(r'\s+', ' ', processed_text).strip()
    
    if ' ' not in text_orig.strip() and ' ' in processed_text:
        return processed_text.replace(' ', '')
    elif not processed_text: 
        return "UNK_SYMBOL" 
    return processed_text

# --- MAPEO IPA A KALDI ---
# --- MAPEO IPA A KALDI ---
IPA_TO_KALDI_MAP = {
    # Vocales
    'a': 'a', 'e': 'e', 'i': 'i', 'o': 'o', 'u': 'u',
    'ə': 'a', # schwa (si aparece, mapear a la vocal más cercana o la más común)
    'ɑ': 'a', # Vocal posterior abierta no redondeada (como en inglés "father") -> a
    'ɛ': 'e', # Vocal anterior semiabierta no redondeada (como en inglés "bed") -> e
    'ɔ': 'o', # Vocal posterior semiabierta redondeada (como en inglés "law") -> o
    'ɪ': 'i', # Vocal anterior casi cerrada casi anterior no redondeada (inglés "bit") -> i
    'ʊ': 'u', # Vocal posterior casi cerrada casi posterior redondeada (inglés "put") -> u

    # Oclusivas
    'p': 'p', 't': 't', 'k': 'k',
    'b': 'b', 'd': 'd', 'g': 'g', # 'g' Kaldi para IPA 'g' o 'ɡ'
    'ɡ': 'g', # Símbolo IPA alternativo para g sonora

    # Fricativas
    'f': 'f', 's': 's', 
    'x': 'x',  # Sonido /x/ (jota española, o ge/gi)
    'θ': 'z',  # Sonido /θ/ (zeta, ce, ci en pronunciación castellana no seseante)
               # Si tu sistema es seseante (Latinoamérica, partes de España), mapea esto a 's': 'θ': 's'
    'ð': 'd',  # Aproximante dental sonora (d suave intervocálica) -> d
    'β': 'b',  # Aproximante bilabial sonora (b/v suave intervocálica) -> b
    'ɣ': 'g',  # Aproximante velar sonora (g suave intervocálica) -> g
    'h': '',   # H aspirada o letra H. En español estándar moderno, la H es muda.
               # Si modelas dialectos con h aspirada, necesitarías un fonema (e.g., 'hh' o 'j').

    # Nasales
    'm': 'm', 'n': 'n', 
    'ɲ': 'ni', # Sonido /ɲ/ (letra ñ)
    'ŋ': 'n',  # N velar (como en "aNca", "aNgustia") -> n (simplificación común)

    # Laterales
    'l': 'l', 
    'ʎ': 'y',  # Sonido /ʎ/ (antigua ll palatal lateral). En la mayoría de dialectos yeístas,
               # este sonido se ha fusionado con /ʝ/ (representado por 'y').

    # Vibrantes
    'ɾ': 'r',  # Vibrante alveolar simple (r suave, como en "peRo", "caRo")
    'r': 'rh', # Vibrante alveolar múltiple (rr fuerte, como en "peRRo", "Rosa")
               # Epitran 'spa-Latn' usa 'r' para esta. La heurística ayudará si es necesario.
    'RR': 'rh',# Si Epitran da "RR" como un segmento IPA (de tu prueba anterior, lo hacía)

    # Aproximantes/Semivocales (para diptongos)
    'j': 'i',  # Como en "hIelo", "reYes" -> i (funciona como vocal en el diptongo)
    'w': 'u',  # Como en "hUevo", "agua" -> u (funciona como vocal en el diptongo)

    # Africadas
    't͡ʃ': 'ch', # Sonido /tʃ/ (letra ch). El símbolo de ligadura puede aparecer.
    'tʃ': 'ch', # Alternativa sin ligadura para /tʃ/.


    'X': 'k s', # Para "éXito", "taXi" -> e k s i t o
    
    '́': '',    # Acento agudo como carácter separado (ignorar, ya normalizado)
    '̃': '',    # Virgulilla de la ñ como carácter separado (ignorar, ɲ ya lo cubre)
    '̈': '',    # Diéresis como carácter separado (ignorar, w o u ya lo cubren en güe/güi)

    'A': 'a', 'B': 'b', 'C': 'k', 'D': 'd', 'E': 'e', 'F': 'f', 'G': 'g',
    'I': 'i', 'J': 'x', 'K': 'k', 'L': 'l', 'M': 'm', 'N': 'n',
    'O': 'o', 'P': 'p', 'Q': 'k', 'R': 'r', 'S': 's', 'T': 't',
    'U': 'u', 'V': 'b', 'W': 'u', 'Y': 'y', 'Z': 's',

    # Números (si Epitran los devuelve como caracteres)
    '0': 's e r o', '1': 'u n o', '2': 'd o s', '3': 't r e s', 
    '4': 'k u a t r o', '5': 's i n k o', '6': 's e i s', 
    '7': 's i e t e', '8': 'o ch o', '9': 'n u e b e',

    # Símbolos
    '/': '',  # Ignorar la barra
    '&': 'i', # Pronunciar '&' como la conjunción "y" (que fonéticamente es 'i')
    # Si Epitran devuelve las letras de un acrónimo como fonemas IPA (poco probable para todos)
    'ʝ': 'y', # Sonido /ʝ/ (letra y) -> y (en dialectos yeístas)
}

# --- HEURÍSTICAS R/RR (sin cambios por ahora) ---
def apply_r_rr_kaldi_heuristics(original_word_upper, kaldi_phoneme_list):
    # ... (tu función apply_r_rr_kaldi_heuristics como estaba) ...
    processed_phonemes = list(kaldi_phoneme_list)
    if not processed_phonemes: return []

    if re.search(r'(N|L|S)R', original_word_upper, re.IGNORECASE):
        for i in range(len(processed_phonemes)):
            if processed_phonemes[i] == 'r':
                processed_phonemes[i] = 'rh'
                break # Cambiar solo la primera r encontrada en este caso
            
    if "RR" in original_word_upper:
        for i in range(len(processed_phonemes)):
            if processed_phonemes[i] == 'r':
                processed_phonemes[i] = 'rh'
        return processed_phonemes
    made_rh_indices = set()
    
    if original_word_upper.startswith("R"):
        for i in range(len(processed_phonemes)):
            if processed_phonemes[i] == 'r':
                processed_phonemes[i] = 'rh'
                made_rh_indices.add(i)
                break 
            
    return processed_phonemes


def ipa_string_to_kaldi_phonemes(word_for_kaldi_lexicon, ipa_string, original_word_for_heuristics):
    """
    Toma una cadena continua de fonemas IPA y la convierte a fonemas Kaldi.
    Esto requiere una segmentación inteligente de la cadena IPA.
    """
    kaldi_phonemes = []
    if not ipa_string:
        return "spn"

    sorted_ipa_keys = sorted(IPA_TO_KALDI_MAP.keys(), key=len, reverse=True)
    
    idx = 0
    while idx < len(ipa_string):
        found_match = False
        for ipa_key in sorted_ipa_keys:
            if ipa_string.startswith(ipa_key, idx):
                kaldi_equivalent = IPA_TO_KALDI_MAP[ipa_key]
                if kaldi_equivalent: # Si no es un mapeo a cadena vacía
                    kaldi_phonemes.extend(kaldi_equivalent.split())
                idx += len(ipa_key)
                found_match = True
                break
        if not found_match:
            # Si no se encontró ningún fonema IPA del mapa, tenemos un problema.
            # Podría ser un carácter no cubierto o un error de segmentación.
            unmapped_char = ipa_string[idx]
            print(f"Advertencia G2P: Carácter/secuencia IPA no mapeado '{unmapped_char}' en '{ipa_string}' (palabra: '{word_for_kaldi_lexicon}'). Usando spn.", file=sys.stderr)
            kaldi_phonemes.append("spn")
            idx += 1
            
    kaldi_phonemes_after_r_rr_heuristics = apply_r_rr_kaldi_heuristics(original_word_for_heuristics.upper(), kaldi_phonemes)
    
    final_kaldi_string = " ".join(p for p in kaldi_phonemes_after_r_rr_heuristics if p)
    return final_kaldi_string if final_kaldi_string else "spn"


# --- Main ---
if __name__ == "__main__":
    palabras_prueba = [
        "HOLA", "MUNDO", "CASA", "PERRO", "GATO", "RELOJ", "RANA", "ISRAEL", "ALREDEDOR", "SUBRAYAR",
        "QUESO", "QUIERO", "GUERRA", "GUITARRA", "PINGÜINO",
        "NIÑO", "MAÑANA",
        "LLAMA", "CALLE", "YO", "YATE",
        "CHILE", "CHOCOLATE",
        "ROSA", "PERRO", "CARRO", "ENRIQUE", "HONRA", "PARRA",
        "BARCELONA", "ZAPATO", "CIELO",
        "ÉXITO", "EXAMEN", "TAXI",
        "ÁRBOL", "ÉPOCA", "ÍNDICE", "ÓPERA", "ÚNICO",
        "AHORA", "ALCOHOL",
        "ACCIÓN", "ACTUAL",
        "TRANSPORTAR", "CONSTRUIR",
        "EUROPA", "REINA", "AIRE", "AUTO", "CIUDAD", "VIUDO",
        "RUTER", "RAUTER", "SUICH", "FAIRWOL", "PROTOCOLO",
        "TECEPE", "IPE", "UDEPE", "ACHETETEPE",
        "TCP/IP", "123GO", "R&D", "WIFI"
    ]
    print("Inicializando Epitran con 'spa-Latn'...")
    try:
        epi = epitran.Epitran('spa-Latn') 
        print("Epitran inicializado.\n")
    except Exception as e:
        print(f"Error inicializando Epitran: {e}", file=sys.stderr)
        # ... (resto del mensaje de error) ...
        sys.exit(1)

    print(f"{'PALABRA ORIG':<20} | {'P. P/EPITRAN':<20} | {'P. P/KALDILEX':<20} | {'IPA (Transliterate)':<35} | {'KALDI PHONEMES':<50}")
    print("-" * 155)

    for palabra_orig_test in palabras_prueba:
        # Palabra que se le pasa a Epitran (con acentos, Ñ, Ü, mayúsculas)
        palabra_a_epitran = palabra_orig_test.upper().strip() 
        # Palabra que irá a la primera columna del lexicón de Kaldi (completamente normalizada)
        palabra_para_kaldi_lex = normalize_word_for_kaldi_lexicon(palabra_orig_test)
        
        if not palabra_a_epitran:
            print(f"{palabra_orig_test:<20} | {'(vacía)':<20} | {palabra_para_kaldi_lex:<20} | {'N/A':<35} | {'N/A':<50}")
            continue

        ipa_direct_string = "ERROR_TRANSLITERATE"
        kaldi_phonemes_str = "ERROR_MAPEO"

        try:
            ipa_direct_string = epi.transliterate(palabra_a_epitran)
            # Pasamos palabra_a_epitran a la heurística de R/RR porque necesita la ortografía original
            kaldi_phonemes_str = ipa_string_to_kaldi_phonemes(palabra_para_kaldi_lex, ipa_direct_string, palabra_a_epitran)
            
            print(f"{palabra_orig_test:<20} | {palabra_a_epitran:<20} | {palabra_para_kaldi_lex:<20} | {ipa_direct_string:<35} | {kaldi_phonemes_str:<50}")

        except Exception as e:
            print(f"ERROR procesando '{palabra_orig_test}': {e}", file=sys.stderr)
            print(f"{palabra_orig_test:<20} | {palabra_a_epitran:<20} | {palabra_para_kaldi_lex:<20} | {str(e)[:30]:<35} | ERROR_MAPEO")
    print("-" * 155)