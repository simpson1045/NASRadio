/// Utility functions for text processing
library;

/// Normalize text for search by removing diacritics and converting to lowercase
/// 
/// This allows "motley crue" to match "Mötley Crüe"
String normalizeTextForSearch(String text) {
  if (text.isEmpty) return '';
  
  // Map of common diacritics to their ASCII equivalents
  const diacriticsMap = {
    'á': 'a', 'à': 'a', 'ä': 'a', 'â': 'a', 'ã': 'a', 'å': 'a',
    'é': 'e', 'è': 'e', 'ë': 'e', 'ê': 'e',
    'í': 'i', 'ì': 'i', 'ï': 'i', 'î': 'i',
    'ó': 'o', 'ò': 'o', 'ö': 'o', 'ô': 'o', 'õ': 'o', 'ø': 'o',
    'ú': 'u', 'ù': 'u', 'ü': 'u', 'û': 'u',
    'ý': 'y', 'ÿ': 'y',
    'ñ': 'n',
    'ç': 'c',
    'Á': 'a', 'À': 'a', 'Ä': 'a', 'Â': 'a', 'Ã': 'a', 'Å': 'a',
    'É': 'e', 'È': 'e', 'Ë': 'e', 'Ê': 'e',
    'Í': 'i', 'Ì': 'i', 'Ï': 'i', 'Î': 'i',
    'Ó': 'o', 'Ò': 'o', 'Ö': 'o', 'Ô': 'o', 'Õ': 'o', 'Ø': 'o',
    'Ú': 'u', 'Ù': 'u', 'Ü': 'u', 'Û': 'u',
    'Ý': 'y', 'Ÿ': 'y',
    'Ñ': 'n',
    'Ç': 'c',
  };
  
  // Replace each diacritic character with its ASCII equivalent
  final buffer = StringBuffer();
  for (int i = 0; i < text.length; i++) {
    final char = text[i];
    buffer.write(diacriticsMap[char] ?? char);
  }
  
  return buffer.toString().toLowerCase().trim();
}
