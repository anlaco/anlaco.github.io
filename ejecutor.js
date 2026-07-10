// Worker ejecutor: corre el binario .wasm en el motor del navegador.
//
// Se lanza uno nuevo por cada corrida y se mata con terminate() si el
// usuario pulsa Detener — por eso un bucle infinito ya no congela nada.
//
// El programa compilado habla WASI (las mismas seis llamadas que usa
// con wasmtime); aquí se las damos en JavaScript:
//   fd_write   → la salida (y los archivos)
//   fd_read    → el teclado (esperando por SharedArrayBuffer) y los archivos
//   path_open  → archivos en memoria, bajo el directorio preabierto fd 3
//   fd_close, random_get, proc_exit
//
// El teclado: el wasm es síncrono y aquí no hay prompt(). El worker
// avisa al hilo principal ({tipo:"pregunta"}) y se duerme con
// Atomics.wait sobre el SharedArrayBuffer; el principal pregunta,
// escribe la respuesta en el buffer y lo despierta.
//   ctrl[0]: 0 = esperando, 1 = respuesta lista, 2 = cancelado
//   ctrl[1]: largo de la respuesta en bytes (UTF-8, desde el byte 8)

"use strict";

// errno de WASI que usamos
const EXITO = 0;
const NOENT = 44; // "no existe" → el preludio da su error amable

let memoria = null;     // la memoria lineal exportada por el programa
let ctrl = null;        // Int32Array sobre el SharedArrayBuffer (o null)
let datosSab = null;    // los bytes de la respuesta del teclado
let archivos = null;    // Map nombre → Uint8Array (vive entre corridas)
let abiertos = null;    // Map fd → {nombre, pos}
let siguienteFd = 4;    // 0-2 son consola, 3 el directorio preabierto
let teclado = null;     // bytes de la línea en curso aún sin entregar
let tecladoPos = 0;

const decodificador = new TextDecoder();

function vista() {
  // siempre fresca: la memoria puede crecer y dejar los buffers viejos
  return new DataView(memoria.buffer);
}

// junta los bytes que señalan los iovecs (puntero, largo) por pares
function bytesDeIovecs(iovs, cuantos) {
  const v = vista();
  const trozos = [];
  let total = 0;
  for (let i = 0; i < cuantos; i++) {
    const puntero = v.getUint32(iovs + i * 8, true);
    const largo = v.getUint32(iovs + i * 8 + 4, true);
    trozos.push(new Uint8Array(memoria.buffer, puntero, largo));
    total += largo;
  }
  const juntos = new Uint8Array(total);
  let pos = 0;
  for (const trozo of trozos) {
    juntos.set(trozo, pos);
    pos += trozo.length;
  }
  return juntos;
}

// pide una línea al hilo principal y se queda dormido hasta la respuesta
function pedirLinea() {
  if (ctrl === null) return null; // sin aislamiento no hay teclado
  Atomics.store(ctrl, 0, 0);
  self.postMessage({ tipo: "pregunta" });
  Atomics.wait(ctrl, 0, 0);
  if (Atomics.load(ctrl, 0) === 2) return null; // canceló el diálogo
  const largo = Atomics.load(ctrl, 1);
  const linea = new Uint8Array(largo + 1);
  linea.set(datosSab.slice(0, largo));
  linea[largo] = 10; // el salto de línea que espera el preludio
  return linea;
}

const wasi = {
  fd_write(fd, iovs, cuantos, escritos) {
    const bytes = bytesDeIovecs(iovs, cuantos);
    if (fd === 1 || fd === 2) {
      self.postMessage({ tipo: "salida", texto: decodificador.decode(bytes) });
    } else if (abiertos.has(fd)) {
      const { nombre } = abiertos.get(fd);
      const viejo = archivos.get(nombre);
      const nuevo = new Uint8Array(viejo.length + bytes.length);
      nuevo.set(viejo);
      nuevo.set(bytes, viejo.length);
      archivos.set(nombre, nuevo);
    } else {
      return 8; // BADF
    }
    vista().setUint32(escritos, bytes.length, true);
    return EXITO;
  },

  fd_read(fd, iovs, cuantos, leidos) {
    let fuente;
    let pos;
    if (fd === 0) {
      if (teclado === null || tecladoPos >= teclado.length) {
        teclado = pedirLinea();
        tecladoPos = 0;
        if (teclado === null) {
          // cancelado (o sin teclado): fin de la entrada
          vista().setUint32(leidos, 0, true);
          return EXITO;
        }
      }
      fuente = teclado;
      pos = tecladoPos;
    } else if (abiertos.has(fd)) {
      const abierto = abiertos.get(fd);
      fuente = archivos.get(abierto.nombre);
      pos = abierto.pos;
    } else {
      return 8; // BADF
    }
    const v = vista();
    let total = 0;
    for (let i = 0; i < cuantos && pos < fuente.length; i++) {
      const puntero = v.getUint32(iovs + i * 8, true);
      const largo = v.getUint32(iovs + i * 8 + 4, true);
      const trozo = fuente.subarray(pos, Math.min(pos + largo, fuente.length));
      new Uint8Array(memoria.buffer, puntero, trozo.length).set(trozo);
      pos += trozo.length;
      total += trozo.length;
    }
    if (fd === 0) tecladoPos = pos;
    else abiertos.get(fd).pos = pos;
    v.setUint32(leidos, total, true);
    return EXITO;
  },

  path_open(dirFd, dirFlags, ruta, rutaLargo, oflags, derechos, derechosHijos, fdflags, resultado) {
    const nombre = decodificador.decode(new Uint8Array(memoria.buffer, ruta, rutaLargo));
    const crear = (oflags & 1) !== 0;   // CREAT
    const vaciar = (oflags & 8) !== 0;  // TRUNC
    const alFinal = (fdflags & 1) !== 0; // APPEND
    if (!archivos.has(nombre) && !crear) return NOENT;
    if (vaciar || !archivos.has(nombre)) archivos.set(nombre, new Uint8Array(0));
    const fd = siguienteFd++;
    abiertos.set(fd, { nombre, pos: alFinal ? archivos.get(nombre).length : 0 });
    vista().setUint32(resultado, fd, true);
    return EXITO;
  },

  fd_close(fd) {
    abiertos.delete(fd);
    return EXITO;
  },

  random_get(puntero, largo) {
    // getRandomValues admite 65536 bytes por llamada como mucho
    for (let pos = 0; pos < largo; pos += 65536) {
      const trozo = Math.min(65536, largo - pos);
      crypto.getRandomValues(new Uint8Array(memoria.buffer, puntero + pos, trozo));
    }
    return EXITO;
  },

  proc_exit(codigo) {
    throw { salidaAnlaco: codigo };
  },
};

self.onmessage = async (evento) => {
  const { wasm, archivos: archivosDeAntes, sab } = evento.data;
  archivos = archivosDeAntes ?? new Map();
  abiertos = new Map();
  if (sab) {
    ctrl = new Int32Array(sab, 0, 2);
    datosSab = new Uint8Array(sab, 8);
  }
  let codigo = 0;
  try {
    const { instance } = await WebAssembly.instantiate(wasm, {
      wasi_snapshot_preview1: wasi,
    });
    memoria = instance.exports.memory;
    instance.exports._start();
  } catch (excepcion) {
    if (excepcion && excepcion.salidaAnlaco !== undefined) {
      codigo = excepcion.salidaAnlaco;
    } else {
      // trampa de WASM (hueco documentado: tipos revueltos en matemáticas)
      self.postMessage({
        tipo: "salida",
        texto: `El programa tropezó con algo que no supo contar mejor:\n${excepcion}\n`,
      });
      codigo = 70;
    }
  }
  self.postMessage({ tipo: "fin", codigo, archivos });
};
