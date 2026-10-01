package studio;

import java.util.*;

/**
 * Translates the engine's Spanish messages to English when STUDIO_LANG=en.
 * Works on fragments so messages built by concatenation are covered too.
 */
final class Msg {
	private static final boolean EN = "en".equals(System.getenv("STUDIO_LANG"));
	private static final List<String[]> PAIRS = new ArrayList<>();

	private static void p(String es, String en) {
		PAIRS.add(new String[] { es, en });
	}

	static {
		// errors
		p("El proyecto está abierto en otra aplicación (¿Ghidra clásico?)", "The project is open in another application (classic Ghidra?)");
		p("Solo se pueden editar estructuras y uniones del programa", "Only the program's structures and unions can be edited");
		p("Espera a que termine el análisis para deshacer", "Wait for analysis to finish before undoing");
		p("Espera a que termine el análisis para rehacer", "Wait for analysis to finish before redoing");
		p("Cierra el programa antes de renombrarlo", "Close the program before renaming it");
		p("Cierra el programa antes de borrarlo", "Close the program before deleting it");
		p("Cierra el programa antes de moverlo", "Close the program before moving it");
		p("Hay programas abiertos en esa carpeta", "There are open programs in that folder");
		p("La instrucción no tiene ninguna constante", "The instruction has no constant");
		p(" con ese valor", " with that value");
		p("La variable no tiene uso en el código", "The variable is not used in the code");
		p("No se pudo inferir ninguna estructura para «", "Couldn't infer a structure for «");
		p("No se pudo iniciar el descompilador: ", "Couldn't start the decompiler: ");
		p("No hay ningún proyecto .gpr en ", "There is no .gpr project in ");
		p("No hay ningún programa abierto", "No program is open");
		p("No hay ningún proyecto abierto", "No project is open");
		p("No hay ninguna instrucción en ", "There is no instruction at ");
		p("No hay ninguna función en ", "There is no function at ");
		p("No se encontró la variable «", "Variable not found «");
		p("No se encontró «", "Not found «");
		p("No se pudo crear la función", "Couldn't create the function");
		p("No se pudo desensamblar", "Couldn't disassemble");
		p("No se pueden comparar: ", "Can't compare: ");
		p("No es un proyecto de Ghidra: ", "Not a Ghidra project: ");
		p("No existe la carpeta ", "Folder doesn't exist: ");
		p("No existe el bloque ", "Block doesn't exist: ");
		p("No existe el tipo ", "Type doesn't exist: ");
		p("No existe: ", "Doesn't exist: ");
		p("No existe ", "Doesn't exist: ");
		p("No es un enum", "Not an enum");
		p("Ghidra no reconoce el formato de ", "Ghidra doesn't recognize the format of ");
		p("Bytes hexadecimales inválidos: ", "Invalid hex bytes: ");
		p("Dirección inválida: ", "Invalid address: ");
		p("Error al descompilar: ", "Decompilation error: ");
		p("La exportación falló: ", "Export failed: ");
		p("Método desconocido: ", "Unknown method: ");
		p("Tipo de script no soportado: ", "Unsupported script type: ");
		p("Tipo desconocido: ", "Unknown type: ");
		p("Exportador desconocido: ", "Unknown exporter: ");
		p("Inicia el emulador primero", "Start the emulator first");
		p("Ya existe un proyecto «", "A project named «");
		p("» en esa carpeta", "» already exists in that folder");
		p("El equate «", "Equate «");
		p("» ya existe con otro valor", "» already exists with a different value");
		p("El programa ", "Program ");
		p(" no está abierto", " is not open");
		p("Falta el parámetro «", "Missing parameter «");
		p("Namespace desconocido", "Unknown namespace");
		// progress & emulator
		p("Importando ", "Importing ");
		p("Abriendo ", "Opening ");
		p("Analizando…", "Analyzing…");
		p("La función ha retornado", "The function has returned");
		p("Punto de ruptura en ", "Breakpoint at ");
		p("pasos alcanzado", "steps reached");
		p("Límite de ", "Limit of ");
		p("Listo en ", "Ready at ");
		p("Detenido", "Stopped");
		p("Paso ", "Step ");
		p(" más)", " more)");
		// undo names (longest first matters for prefixes)
		p("Aplicar archivo de tipos", "Apply Type Archive");
		p("Comentario de función", "Function Comment");
		p("Opciones de análisis", "Analysis Options");
		p("Permisos de bloque", "Block Permissions");
		p("Renombrar variable", "Rename Variable");
		p("Renombrar bloque", "Rename Block");
		p("Renombrar tipo", "Rename Type");
		p("Aplicar nombres", "Apply Names");
		p("Añadir referencia", "Add Reference");
		p("Quitar referencia", "Remove Reference");
		p("Crear estructura", "Create Structure");
		p("Quitar marcador", "Remove Bookmark");
		p("Parchear bytes", "Patch Bytes");
		p("Borrar etiqueta", "Delete Label");
		p("Crear etiqueta", "Create Label");
		p("Borrar función", "Delete Function");
		p("Crear función", "Create Function");
		p("Añadir bloque", "Add Block");
		p("Borrar bloque", "Delete Block");
		p("Añadir campo", "Add Field");
		p("Borrar campo", "Delete Field");
		p("Editar campo", "Edit Field");
		p("Añadir valor", "Add Value");
		p("Borrar código", "Clear Code");
		p("Borrar tipo", "Delete Type");
		p("Cambiar tipo", "Change Type");
		p("Crear typedef", "Create Typedef");
		p("Crear unión", "Create Union");
		p("Crear enum", "Create Enum");
		p("Definir dato", "Define Data");
		p("Desensamblar", "Disassemble");
		p("Editar firma", "Edit Signature");
		p("Auto-análisis", "Auto-analysis");
		p("Importar C", "Import C");
		p("Ensamblar", "Assemble");
		p("Comentario", "Comment");
		p("Marcador", "Bookmark");
		p("Renombrar", "Rename");
		PAIRS.sort((a, b) -> b[0].length() - a[0].length());
	}

	private Msg() {
	}

	static String t(String s) {
		if (!EN || s == null) {
			return s;
		}
		String out = s;
		for (String[] pair : PAIRS) {
			if (out.contains(pair[0])) {
				out = out.replace(pair[0], pair[1]);
			}
		}
		return out;
	}
}
