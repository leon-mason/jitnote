package io.github.leonmason.gitnotebook.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

private val Light = lightColorScheme(
    primary = Color(0xFF1F6F5C),
    onPrimary = Color.White,
    primaryContainer = Color(0xFFA8F2D8),
    onPrimaryContainer = Color(0xFF002019),
    secondary = Color(0xFF4B635A),
    secondaryContainer = Color(0xFFCDE9DD),
    onSecondaryContainer = Color(0xFF072019),
    tertiaryContainer = Color(0xFFFFE0B2),
    onTertiaryContainer = Color(0xFF2E1500),
    background = Color(0xFFFBFDFB),
    surface = Color(0xFFFBFDFB),
    surfaceContainer = Color(0xFFEFF3F1),
    surfaceContainerHigh = Color(0xFFE9EEEB),
    surfaceContainerLow = Color(0xFFF4F8F6),
)

private val Dark = darkColorScheme(
    primary = Color(0xFF84D6BD),
    onPrimary = Color(0xFF00382D),
    primaryContainer = Color(0xFF005143),
    onPrimaryContainer = Color(0xFFA8F2D8),
    secondary = Color(0xFFB2CCC1),
    secondaryContainer = Color(0xFF344C43),
    onSecondaryContainer = Color(0xFFCDE9DD),
    tertiaryContainer = Color(0xFF5A3A12),
    onTertiaryContainer = Color(0xFFFFDDB3),
    background = Color(0xFF121614),
    surface = Color(0xFF121614),
    surfaceContainer = Color(0xFF1D2220),
    surfaceContainerHigh = Color(0xFF272D2A),
    surfaceContainerLow = Color(0xFF191E1C),
)

@Composable
fun GitNotebookTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = if (isSystemInDarkTheme()) Dark else Light, content = content)
}
