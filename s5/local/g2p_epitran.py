#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import epitran
import unicodedata # Necesario para normalize_word_for_epitran si se usa NFD
import re          # Necesario para normalize_word_for_epitran si se usa sub
import sys

# --- FUNCIÓN DE PREPARACIÓN DE PALABRA PARA EPITRAN ---
# Esta función toma la palabra que viene de combined_oov_for_g2p.txt.
# combined_oov_for_g2p.txt ya contiene palabras normalizadas por normalize_unicode.py
# (MAYÚSCULAS, sin acentos, Ñ->N, Ü->U, solo A-Z0-9N, y sin espacios si eran una sola unidad).
# Epitran generalmente prefiere la ortografía original con acentos, Ñ, Ü para una mejor
# transcripción fonética. Sin embargo, como ya hemos normalizado para la clave del lexicón,
# le pasaremos esa versión normalizada a Epitran.
# Esta función podría simplemente devolver la palabra tal cual, o hacer una limpieza mínima
# si Epitran es sensible a algún carácter que normalize_unicode.py podría dejar.
def prepare_word_for_epitran(text_input_normalized_lex_key):
    # text_input_normalized_lex_key es, por ejemplo, "TCPIP" o "BIGDATA" o "ALGORITMO"
    # Epitran maneja bien las mayúsculas.
    # Ya no debería haber caracteres "raros" si normalize_unicode.py hizo su trabajo.
    return text_input_normalized_lex_key.strip() # Solo un strip por si acaso.

# --- MAPEO IPA A KALDI (DEBE SER EL MISMO QUE PERFECCIONASTE EN test_epitran.py) ---
IPA_TO_KALDI_MAP = {
    # Vocales
    'a': 'a', 'e': 'e', 'i': 'i', 'o': 'o', 'u': 'u',
    'ə': 'a', 'ɑ': 'a', 'ɛ': 'e', 'ɔ': 'o', 'ɪ': 'i', 'ʊ': 'u',
    # Oclusivas
    'p': 'p', 't': 't', 'k': 'k', 'b': 'b', 'd': 'd', 'g': 'g', 'ɡ': 'g',
    # Fricativas
    'f': 'f', 's': 's', 'x': 'x', 'θ': 'z', 
    'ð': 'd', 'β': 'b', 'ɣ': 'g', 'h': '',
    # Nasales
    'm': 'm', 'n': 'n', 'ɲ': 'ni', 'ŋ': 'n',
    # Laterales
    'l': 'l', 'ʎ': 'y', 'ʝ': 'y',
    # Vibrantes
    'ɾ': 'r', 'r': 'rh', 'RR': 'rh',
    # Aproximantes/Semivocales
    'j': 'i', 'w': 'u',
    # Africadas
    't͡ʃ': 'ch', 'tʃ': 'ch',
    # Símbolos y caracteres especiales que podrían aparecer en la salida IPA de Epitran
    'X': 'k s',
    '́': '', '̃': '', '̈': '', # Acentos y diacríticos como caracteres separados
    '/': '', '&': 'i',
    # Números (si Epitran los devuelve como caracteres en su salida IPA)
    '0': 's e r o', '1': 'u n o', '2': 'd o s', '3': 't r e s', 
    '4': 'k u a t r o', '5': 's i n k o', '6': 's e i s', 
    '7': 's i e t e', '8': 'o ch o', '9': 'n u e b e',
}

# --- HEURÍSTICAS R/RR (DEBE SER LA MISMA QUE PERFECCIONASTE EN test_epitran.py) ---
def apply_r_rr_kaldi_heuristics(original_word_upper, kaldi_phoneme_list):
    processed_phonemes = list(kaldi_phoneme_list)
    if not processed_phonemes: return []

    made_rh_indices = set()

    # Heurística NLS+R primero, ya que puede afectar a 'r's que luego no deberían ser tocadas por R-inicial
    if re.search(r'(N|L|S)R', original_word_upper, re.IGNORECASE):
        for i in range(len(processed_phonemes)):
            if processed_phonemes[i] == 'r': # Encontramos una r simple
                processed_phonemes[i] = 'rh'
                made_rh_indices.add(i)
                break 
                
    # Heurística de "RR" ortográfico (más fuerte que las otras si no es R inicial)
    if "RR" in original_word_upper:
        for i in range(len(processed_phonemes)):
            if processed_phonemes[i] == 'r' and i not in made_rh_indices:
                processed_phonemes[i] = 'rh'

    # Heurística de "R" al inicio de palabra
    if original_word_upper.startswith("R"):
        for i in range(len(processed_phonemes)):
            if processed_phonemes[i] == 'r' and i not in made_rh_indices : # Solo si no fue afectada por NLS+R
                processed_phonemes[i] = 'rh'
                break 
            elif processed_phonemes[i] == 'rh': # Si ya es rh (por NLS+R), no hacer nada más
                break
            
    return processed_phonemes

# --- FUNCIÓN PRINCIPAL DE CONVERSIÓN IPA A KALDI ---
def ipa_string_to_kaldi_phonemes(word_for_kaldi_lexicon, ipa_string, original_word_for_heuristics):
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
                if kaldi_equivalent: 
                    kaldi_phonemes.extend(kaldi_equivalent.split())
                idx += len(ipa_key)
                found_match = True
                break
        if not found_match:
            unmapped_char = ipa_string[idx]
            kaldi_phonemes.append("spn")
            idx += 1
            
    kaldi_phonemes_after_r_rr_heuristics = apply_r_rr_kaldi_heuristics(original_word_for_heuristics, kaldi_phonemes)
    
    final_kaldi_string = " ".join(p for p in kaldi_phonemes_after_r_rr_heuristics if p)
    return final_kaldi_string if final_kaldi_string else "spn"

# --- BLOQUE MAIN ---
if __name__ == "__main__":
    try:
        epi = epitran.Epitran('spa-Latn')
    except Exception as e:
        sys.stderr.write(f"Error inicializando Epitran: {e}\n")
        sys.stderr.write("Asegúrate de haber instalado los modelos: python -m epitran_scripts.download 'spa-Latn'\n")
        sys.exit(1)

    for line_stdin in sys.stdin:
        # La palabra de entrada (word_key_for_lexicon) ya viene normalizada 
        # (MAYÚSCULAS, sin acentos, Ñ->N, Ü->U, etc.) 
        # desde lang_prep.sh
        word_key_for_lexicon = line_stdin.strip()
        if not word_key_for_lexicon:
            continue
        
        # La palabra que se pasa a Epitran y a la heurística R/RR.
        word_for_epitran_and_r_rr = prepare_word_for_epitran(word_key_for_lexicon)
            
        if not word_for_epitran_and_r_rr: # Si la preparación la deja vacía
            sys.stdout.write(f"{word_key_for_lexicon} spn\n")
            continue

        try:
            ipa_direct_string = epi.transliterate(word_for_epitran_and_r_rr)
            kaldi_phonemes_str = ipa_string_to_kaldi_phonemes(
                word_key_for_lexicon, 
                ipa_direct_string, 
                word_for_epitran_and_r_rr # Pasar la misma palabra usada para transliterar a la heurística
            )
            
            sys.stdout.write(f"{word_key_for_lexicon} {kaldi_phonemes_str}\n")

        except Exception as e:
            sys.stderr.write(f"Error G2P procesando palabra '{word_key_for_lexicon}': {e}\n")
            sys.stdout.write(f"{word_key_for_lexicon} spn\n") # Fallback