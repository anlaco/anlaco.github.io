// El worker de Ana: carga Pyodide una vez y atiende dos oficios.
//
// 1. COMPILAR: fuente .ana → binario .wasm (compilar + ensamblar, la
//    misma cadena que `anlaco compilar`). El programa corre después en
//    el worker ejecutor. Traducir y formatear también se atienden aquí.
// 2. LA CONSOLA: la sesión viva del intérprete (el mismo repl de la
//    terminal). Escribes una frase, se ejecuta al momento, y las
//    variables se recuerdan entre frase y frase — de ahí sale también
//    el panel de variables del IDE.
//
// Si la consola pregunta (`la respuesta a`), este worker se duerme con
// Atomics sobre un SharedArrayBuffer hasta que el hilo principal
// contesta — igual que hace el ejecutor. Y si una frase no acaba nunca,
// el principal puede cortarla por el buffer de interrupción de Pyodide
// sin perder la sesión.

importScripts("rueda.js");
importScripts("https://cdn.jsdelivr.net/pyodide/v0.26.4/full/pyodide.js");

let sabConsola = null; // SharedArrayBuffer del teclado de la consola

// La consola pide una línea y espera dormida; Python la llama como
// js.pedirLinea(pregunta) — la pregunta viaja aquí porque la salida de
// la consola va en búfer y aún no está en la página.
function pedirLinea(pregunta) {
  if (sabConsola === null) return null;
  const ctrl = new Int32Array(sabConsola, 0, 2);
  Atomics.store(ctrl, 0, 0);
  self.postMessage({ tipo: "pregunta", pregunta });
  Atomics.wait(ctrl, 0, 0);
  if (Atomics.load(ctrl, 0) === 2) return null; // canceló el diálogo
  const largo = Atomics.load(ctrl, 1);
  return new TextDecoder().decode(new Uint8Array(sabConsola, 8, largo).slice());
}
self.pedirLinea = pedirLinea;

// El puente: errores de Anlaco vuelven ya presentados, no como excepción.
const PUENTE = `
import json
import js
from anlaco.lexer import detectar_idioma, frases_de_idioma
from anlaco.tokens import TokenType
from anlaco import ast_nodes as ast
from anlaco.compilador import compilar
from anlaco.wat2wasm import ensamblar
from anlaco.errors import ErrorDeAnlaco
from anlaco.cli import presentar_error
from anlaco.emisor import traducir, formatear
from anlaco.interpreter import Interprete
from anlaco.parser import parse

ERROR = None

def compilar_web(fuente):
    """El binario .wasm del programa, o None dejando el error en ERROR."""
    global ERROR
    ERROR = None
    try:
        return ensamblar(compilar(fuente))
    except ErrorDeAnlaco as error:
        ERROR = presentar_error(error, fuente)
        return None

def traducir_web(fuente):
    global ERROR
    ERROR = None
    try:
        destino = "en" if detectar_idioma(fuente) == "es" else "es"
        return traducir(fuente, destino)
    except ErrorDeAnlaco as error:
        ERROR = presentar_error(error, fuente)
        return None

def formatear_web(fuente):
    global ERROR
    ERROR = None
    try:
        return formatear(fuente)
    except ErrorDeAnlaco as error:
        ERROR = presentar_error(error, fuente)
        return None

# --- la consola: una sesión viva del intérprete, como el repl ---

class SalidaConsola:
    def __init__(self):
        self.partes = []

    def write(self, texto):
        self.partes.append(str(texto))

    def flush(self):
        pass

    def recoger(self):
        texto = "".join(self.partes)
        self.partes = []
        return texto

class EntradaConsola:
    """'la respuesta a' pregunta por el diálogo del navegador."""

    def __init__(self, salida):
        self.salida = salida

    def readline(self):
        lineas = "".join(self.salida.partes).rstrip("\\n").split("\\n")
        pregunta = lineas[-1] if lineas and lineas[-1] else "..."
        contestado = js.pedirLinea(pregunta)
        if contestado is None:
            return ""
        self.salida.write(str(contestado) + "\\n")  # el eco, como en la terminal
        return str(contestado) + "\\n"

class Consola:
    def __init__(self, idioma="es"):
        frases = frases_de_idioma(idioma)
        self.palabra_fin = frases[TokenType.KW_END][0]
        self.frase_si_no = frases[TokenType.KW_ELSE][0]
        self.idioma = idioma
        self.salida = SalidaConsola()
        self.interprete = Interprete(entrada=EntradaConsola(self.salida),
                                     salida=self.salida, idioma=idioma)
        self.pendientes = []
        self.abiertos = 0

    def linea(self, linea):
        """Una línea más; ejecuta cuando el fragmento queda cerrado."""
        limpia = linea.strip()
        if not self.pendientes and limpia == "":
            return {"salida": "", "abierta": False}
        self.pendientes.append(linea)
        if limpia.endswith(":") and not limpia.startswith(self.frase_si_no):
            self.abiertos += 1
        elif limpia == self.palabra_fin:
            self.abiertos -= 1
        if self.abiertos > 0:
            return {"salida": "", "abierta": True}
        fragmento = "\\n".join(self.pendientes)
        self.pendientes = []
        self.abiertos = 0
        try:
            programa = parse(fragmento, self.idioma)
            for sentencia in programa.sentencias:
                if isinstance(sentencia, ast.Define):
                    self.interprete.funciones[sentencia.nombre] = sentencia
            for sentencia in programa.sentencias:
                if not isinstance(sentencia, ast.Define):
                    self.interprete.sentencia(sentencia, self.interprete.globales)
        except ErrorDeAnlaco as error:
            self.salida.write(error.mensaje + "\\n")
        except KeyboardInterrupt:
            self.salida.write("■ Frase cortada.\\n")
        return {"salida": self.salida.recoger(), "abierta": False}

    def variables(self):
        """[nombre, valor legible] de la sesión, más las funciones."""
        filas = [[nombre, self.interprete.mostrar(valor)]
                 for nombre, valor in self.interprete.globales.variables.items()]
        filas += [[nombre, "(función)"] for nombre in self.interprete.funciones]
        return filas

CONSOLA = Consola()

def consola_web(linea):
    global CONSOLA
    try:
        return json.dumps(CONSOLA.linea(linea))
    except KeyboardInterrupt:
        CONSOLA.pendientes, CONSOLA.abiertos = [], 0
        return json.dumps({"salida": "■ Frase cortada.\\n", "abierta": False})

def variables_web():
    return json.dumps(CONSOLA.variables())

def reiniciar_consola():
    global CONSOLA
    CONSOLA = Consola()
    return json.dumps([])
`;

let pyodide = null;

async function arrancar() {
  pyodide = await loadPyodide();
  self.postMessage({ tipo: "estado", texto: "Instalando el compilador…" });
  await pyodide.loadPackage("micropip");
  const micropip = pyodide.pyimport("micropip");
  await micropip.install(new URL(ANLACO_WHEEL, self.location.href).href);
  pyodide.runPython(PUENTE);
  self.postMessage({ tipo: "listo" });
}

const arranque = arrancar().catch((excepcion) =>
  self.postMessage({ tipo: "error_arranque", texto: String(excepcion.message ?? excepcion) })
);

self.onmessage = async (evento) => {
  await arranque;
  const { id, accion, fuente, sab, corte } = evento.data;
  if (accion === "conectar") {
    // el teclado de la consola y el botón de cortar, una sola vez
    sabConsola = sab ?? null;
    if (corte) pyodide.setInterruptBuffer(new Uint8Array(corte));
    return;
  }
  try {
    if (accion === "compilar" || accion === "traducir" || accion === "formatear") {
      const resultado = pyodide.globals.get(`${accion}_web`)(fuente);
      if (resultado === undefined || resultado === null) {
        self.postMessage({ id, tipo: "error", texto: pyodide.globals.get("ERROR") });
      } else if (accion === "compilar") {
        const wasm = new Uint8Array(resultado.toJs()); // copia propia, fuera de Pyodide
        resultado.destroy();
        self.postMessage({ id, tipo: "wasm", wasm }, [wasm.buffer]);
      } else {
        self.postMessage({ id, tipo: "texto", texto: resultado });
      }
    } else if (accion === "consola") {
      const eco = JSON.parse(pyodide.globals.get("consola_web")(fuente));
      const variables = JSON.parse(pyodide.globals.get("variables_web")());
      self.postMessage({ id, tipo: "consola", ...eco, variables });
    } else if (accion === "reiniciar") {
      pyodide.globals.get("reiniciar_consola")();
      self.postMessage({ id, tipo: "consola", salida: "", abierta: false, variables: [] });
    }
  } catch (excepcion) {
    self.postMessage({
      id,
      tipo: "error",
      texto: `Algo se rompió por dentro:\n${excepcion.message ?? excepcion}`,
    });
  }
};
