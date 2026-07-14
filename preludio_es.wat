;; Tiempo de ejecución de Anlaco compilado a WebAssembly (WasmGC + WASI).
;;
;; Este archivo son los "campos" del módulo: el compilador lo envuelve en
;; (module ...) y le añade los datos, las variables y la función _start.
;; Los huecos {msg_...} los rellena el compilador con los mensajes de error
;; en el idioma del programa.
;;
;; Números (decisión 2026-07-08): los enteros son ILIMITADOS (bignum), fieles
;; a la especificación. Un entero es un array de "limbs" de 32 bits en base
;; 2^32, del menos al más significativo, sin ceros por arriba; el cero es el
;; array vacío. El signo va aparte (0 positivo, 1 negativo). Los decimales
;; son f64, como en el intérprete (float de Python).

(import "wasi_snapshot_preview1" "fd_write"
  (func $fd_write (param i32 i32 i32 i32) (result i32)))
(import "wasi_snapshot_preview1" "fd_read"
  (func $fd_read (param i32 i32 i32 i32) (result i32)))
(import "wasi_snapshot_preview1" "proc_exit"
  (func $proc_exit (param i32)))
(import "wasi_snapshot_preview1" "random_get"
  (func $random_get (param i32 i32) (result i32)))
(import "wasi_snapshot_preview1" "path_open"
  (func $path_open (param i32 i32 i32 i32 i32 i64 i64 i32 i32) (result i32)))
(import "wasi_snapshot_preview1" "fd_close"
  (func $fd_close (param i32) (result i32)))
(import "wasi_snapshot_preview1" "args_sizes_get"
  (func $args_sizes_get (param i32 i32) (result i32)))
(import "wasi_snapshot_preview1" "args_get"
  (func $args_get (param i32 i32) (result i32)))

(type $Limbs (array (mut i32)))
(type $Entero (struct (field $neg i32) (field $limbs (ref $Limbs))))
(type $Decimal (struct (field $v f64)))
(type $Texto (array (mut i8)))
(type $Items (array (mut anyref)))
(type $Lista (struct (field $n (mut i32)) (field $items (mut (ref $Items)))))
;; una tarjeta (registro): tipo + campos (sus nombres, en orden de declaración)
;; + valores (paralelo a campos). Reusa $Items para ambos arreglos.
(type $Tarjeta (struct (field $tipo (ref $Texto))
                        (field $campos (ref $Items))
                        (field $valores (ref $Items))))

(memory (export "memory") 1)

;; caché de texto→lista de letras (4 huecos rotatorios): el lexer autoalojado
;; pide letra a letra un fuente entero y sin esto cada acceso reconstruiría
;; la lista completa (cuadrático). Los textos de Ana son inmutables, así que
;; cachear por identidad de objeto no cambia ninguna semántica.
(global $ct0 (mut anyref) (ref.null any))
(global $cl0 (mut anyref) (ref.null any))
(global $ct1 (mut anyref) (ref.null any))
(global $cl1 (mut anyref) (ref.null any))
(global $ct2 (mut anyref) (ref.null any))
(global $cl2 (mut anyref) (ref.null any))
(global $ct3 (mut anyref) (ref.null any))
(global $cl3 (mut anyref) (ref.null any))
(global $c_sig (mut i32) (i32.const 0))

(data $msg_div0 "Error: No se puede dividir entre cero.")
(data $msg_cond_pre "Error: La condici\c3\b3n tiene que ser verdadero o falso, y aqu\c3\ad vale ")
(data $msg_cond_post ".")
(data $msg_entero_pre "Error: Aqu\c3\ad esperaba un n\c3\bamero entero, pero hay ")
(data $msg_entero_post ".")
(data $msg_verdadero "verdadero")
(data $msg_falso "falso")
(data $msg_nada "nada")
(data $msg_sin_respuesta "Error: El programa esperaba una respuesta y no lleg\c3\b3 ninguna.")
(data $msg_llamadas "Error: Demasiadas llamadas anidadas (m\c3\a1s de 1000). \c2\bfUna funci\c3\b3n que se llama a s\c3\ad misma sin parar?")
(data $msg_lista_pre "Error: Aqu\c3\ad esperaba una lista o un texto, pero hay ")
(data $msg_lista_post ".")
(data $msg_indice_pre "Error: La lista tiene ")
(data $msg_indice_mid " elementos y pediste el ")
(data $msg_indice_post ".")
(data $msg_vacia_primero "Error: La lista est\c3\a1 vac\c3\ada: no tiene primero.")
(data $msg_vacia_ultimo "Error: La lista est\c3\a1 vac\c3\ada: no tiene \c3\baltimo.")
(data $msg_indice_texto_pre "Error: El texto tiene ")
(data $msg_indice_texto_mid " letras y pediste la ")
(data $msg_indice_texto_post ".")
(data $msg_texto_vacio_primero "Error: El texto est\c3\a1 vac\c3\ado: no tiene primera letra.")
(data $msg_texto_vacio_ultimo "Error: El texto est\c3\a1 vac\c3\ado: no tiene \c3\baltima letra.")
(data $msg_anade_pre "Error: \"a\c3\b1ade\" necesita una lista o el nombre de un archivo, y aqu\c3\ad hay ")
(data $msg_anade_post ".")
(data $msg_azar_pre "Error: \"al azar entre ")
(data $msg_azar_mid " y ")
(data $msg_azar_post "\": el primero no puede ser mayor.")
(data $msg_texto_pre "Error: Aqu\c3\ad esperaba un texto, pero hay ")
(data $msg_texto_post ".")
(data $msg_archivo_pre "Error: No encuentro el archivo \"")
(data $msg_archivo_post "\".")
(data $msg_campo_pre "Error: Esa tarjeta no tiene ning\c3\ban campo llamado ")
(data $msg_campo_post ".")

;; --- frontera WASI: la memoria lineal solo se usa aquí ---
;; 0..7 iovec (puntero, largo) - 8..11 bytes escritos - 16.. buffer de copia

(func $escribe_fd (param $fd i32) (param $texto (ref $Texto)) (param $salto i32)
  (local $largo i32)
  (local $i i32)
  (local.set $largo (array.len (local.get $texto)))
  ;; si el texto no cabe en las páginas que hay, pide más
  (block $cabe
    (br_if $cabe (i32.lt_u (i32.add (local.get $largo) (i32.const 32))
                           (i32.mul (memory.size) (i32.const 65536))))
    (drop (memory.grow (i32.add (i32.div_u (local.get $largo) (i32.const 65536))
                                (i32.const 1)))))
  (block $fin_copia
    (loop $copia
      (br_if $fin_copia (i32.ge_u (local.get $i) (local.get $largo)))
      (i32.store8 (i32.add (i32.const 16) (local.get $i))
                  (array.get_u $Texto (local.get $texto) (local.get $i)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $copia)))
  (if (local.get $salto)
    (then
      (i32.store8 (i32.add (i32.const 16) (local.get $largo)) (i32.const 10))
      (local.set $largo (i32.add (local.get $largo) (i32.const 1)))))
  (i32.store (i32.const 0) (i32.const 16))
  (i32.store (i32.const 4) (local.get $largo))
  (drop (call $fd_write (local.get $fd) (i32.const 0) (i32.const 1) (i32.const 8))))

(func $escribe (param $texto (ref $Texto))
  (call $escribe_fd (i32.const 1) (local.get $texto) (i32.const 1)))

;; error en tiempo de ejecución: mensaje por la salida de errores y fuera
(func $panico (param $mensaje (ref $Texto))
  (call $escribe_fd (i32.const 2) (local.get $mensaje) (i32.const 1))
  (call $proc_exit (i32.const 1)))

;; --- textos ---

(func $concatenar (param $a (ref $Texto)) (param $b (ref $Texto)) (result (ref $Texto))
  (local $la i32)
  (local $lb i32)
  (local $r (ref $Texto))
  (local.set $la (array.len (local.get $a)))
  (local.set $lb (array.len (local.get $b)))
  (local.set $r (array.new $Texto (i32.const 0) (i32.add (local.get $la) (local.get $lb))))
  (array.copy $Texto $Texto (local.get $r) (i32.const 0)
              (local.get $a) (i32.const 0) (local.get $la))
  (array.copy $Texto $Texto (local.get $r) (local.get $la)
              (local.get $b) (i32.const 0) (local.get $lb))
  (local.get $r))

;; --- magnitudes (arrays de limbs, siempre sin signo) ---

(func $cero (result (ref $Entero))
  (struct.new $Entero (i32.const 0) (array.new_fixed $Limbs 0)))

;; quita los ceros por arriba (deja el array tal cual si ya está limpio)
(func $limbs_recorta (param $a (ref null $Limbs)) (result (ref $Limbs))
  (local $n i32)
  (local $r (ref $Limbs))
  (local.set $n (array.len (local.get $a)))
  (block $listo
    (loop $busca
      (br_if $listo (i32.eqz (local.get $n)))
      (br_if $listo (i32.ne (array.get $Limbs (local.get $a)
                                       (i32.sub (local.get $n) (i32.const 1)))
                            (i32.const 0)))
      (local.set $n (i32.sub (local.get $n) (i32.const 1)))
      (br $busca)))
  (if (i32.eq (local.get $n) (array.len (local.get $a)))
    (then (return (ref.as_non_null (local.get $a)))))
  (local.set $r (array.new $Limbs (i32.const 0) (local.get $n)))
  (array.copy $Limbs $Limbs (local.get $r) (i32.const 0)
              (local.get $a) (i32.const 0) (local.get $n))
  (local.get $r))

;; compara magnitudes: -1 si a<b, 0 si iguales, 1 si a>b
(func $limbs_compara (param $a (ref null $Limbs)) (param $b (ref null $Limbs)) (result i32)
  (local $la i32)
  (local $lb i32)
  (local $i i32)
  (local $x i32)
  (local $y i32)
  (local.set $la (array.len (local.get $a)))
  (local.set $lb (array.len (local.get $b)))
  (if (i32.ne (local.get $la) (local.get $lb))
    (then (return (select (i32.const -1) (i32.const 1)
                          (i32.lt_u (local.get $la) (local.get $lb))))))
  (local.set $i (local.get $la))
  (block $fin
    (loop $baja
      (br_if $fin (i32.eqz (local.get $i)))
      (local.set $i (i32.sub (local.get $i) (i32.const 1)))
      (local.set $x (array.get $Limbs (local.get $a) (local.get $i)))
      (local.set $y (array.get $Limbs (local.get $b) (local.get $i)))
      (if (i32.lt_u (local.get $x) (local.get $y)) (then (return (i32.const -1))))
      (if (i32.gt_u (local.get $x) (local.get $y)) (then (return (i32.const 1))))
      (br $baja)))
  (i32.const 0))

;; suma de magnitudes: la suma del colegio, limb a limb con acarreo
(func $limbs_suma (param $a (ref null $Limbs)) (param $b (ref null $Limbs)) (result (ref $Limbs))
  (local $la i32)
  (local $lb i32)
  (local $i i32)
  (local $t i64)
  (local $acarreo i64)
  (local $r (ref $Limbs))
  (local $cambio (ref null $Limbs))
  ;; que a sea el largo
  (if (i32.lt_u (array.len (local.get $a)) (array.len (local.get $b)))
    (then
      (local.set $cambio (local.get $a))
      (local.set $a (local.get $b))
      (local.set $b (local.get $cambio))))
  (local.set $la (array.len (local.get $a)))
  (local.set $lb (array.len (local.get $b)))
  (local.set $r (array.new $Limbs (i32.const 0) (i32.add (local.get $la) (i32.const 1))))
  ;; primera fase: donde a y b tienen limb
  (block $fin_comun
    (loop $comun
      (br_if $fin_comun (i32.ge_u (local.get $i) (local.get $lb)))
      (local.set $t (i64.add
        (i64.add (i64.extend_i32_u (array.get $Limbs (local.get $a) (local.get $i)))
                 (i64.extend_i32_u (array.get $Limbs (local.get $b) (local.get $i))))
        (local.get $acarreo)))
      (array.set $Limbs (local.get $r) (local.get $i) (i32.wrap_i64 (local.get $t)))
      (local.set $acarreo (i64.shr_u (local.get $t) (i64.const 32)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $comun)))
  ;; segunda fase: la cola de a, solo con el acarreo
  (block $fin_cola
    (loop $cola
      (br_if $fin_cola (i32.ge_u (local.get $i) (local.get $la)))
      (local.set $t (i64.add
        (i64.extend_i32_u (array.get $Limbs (local.get $a) (local.get $i)))
        (local.get $acarreo)))
      (array.set $Limbs (local.get $r) (local.get $i) (i32.wrap_i64 (local.get $t)))
      (local.set $acarreo (i64.shr_u (local.get $t) (i64.const 32)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $cola)))
  (array.set $Limbs (local.get $r) (local.get $la) (i32.wrap_i64 (local.get $acarreo)))
  (call $limbs_recorta (local.get $r)))

;; resta de magnitudes (exige a >= b): la resta del colegio, con préstamo
(func $limbs_resta (param $a (ref null $Limbs)) (param $b (ref null $Limbs)) (result (ref $Limbs))
  (local $la i32)
  (local $lb i32)
  (local $i i32)
  (local $t i64)
  (local $prestamo i64)
  (local $r (ref $Limbs))
  (local.set $la (array.len (local.get $a)))
  (local.set $lb (array.len (local.get $b)))
  (local.set $r (array.new $Limbs (i32.const 0) (local.get $la)))
  ;; primera fase: donde a y b tienen limb
  (block $fin_comun
    (loop $comun
      (br_if $fin_comun (i32.ge_u (local.get $i) (local.get $lb)))
      (local.set $t (i64.sub
        (i64.sub (i64.extend_i32_u (array.get $Limbs (local.get $a) (local.get $i)))
                 (i64.extend_i32_u (array.get $Limbs (local.get $b) (local.get $i))))
        (local.get $prestamo)))
      (array.set $Limbs (local.get $r) (local.get $i) (i32.wrap_i64 (local.get $t)))
      (local.set $prestamo (i64.and (i64.shr_u (local.get $t) (i64.const 63)) (i64.const 1)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $comun)))
  ;; segunda fase: la cola de a, solo con el préstamo
  (block $fin_cola
    (loop $cola
      (br_if $fin_cola (i32.ge_u (local.get $i) (local.get $la)))
      (local.set $t (i64.sub
        (i64.extend_i32_u (array.get $Limbs (local.get $a) (local.get $i)))
        (local.get $prestamo)))
      (array.set $Limbs (local.get $r) (local.get $i) (i32.wrap_i64 (local.get $t)))
      (local.set $prestamo (i64.and (i64.shr_u (local.get $t) (i64.const 63)) (i64.const 1)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $cola)))
  (call $limbs_recorta (local.get $r)))

;; multiplicación de magnitudes: la del colegio, fila a fila, O(n*m)
(func $limbs_multiplica (param $a (ref null $Limbs)) (param $b (ref null $Limbs)) (result (ref $Limbs))
  (local $la i32)
  (local $lb i32)
  (local $i i32)
  (local $j i32)
  (local $ai i64)
  (local $t i64)
  (local $acarreo i64)
  (local $r (ref $Limbs))
  (local.set $la (array.len (local.get $a)))
  (local.set $lb (array.len (local.get $b)))
  (if (i32.or (i32.eqz (local.get $la)) (i32.eqz (local.get $lb)))
    (then (return (array.new_fixed $Limbs 0))))
  (local.set $r (array.new $Limbs (i32.const 0) (i32.add (local.get $la) (local.get $lb))))
  (block $fin_filas
    (loop $fila
      (br_if $fin_filas (i32.ge_u (local.get $i) (local.get $la)))
      (local.set $ai (i64.extend_i32_u (array.get $Limbs (local.get $a) (local.get $i))))
      (local.set $acarreo (i64.const 0))
      (local.set $j (i32.const 0))
      (block $fin_fila
        (loop $celda
          (br_if $fin_fila (i32.ge_u (local.get $j) (local.get $lb)))
          (local.set $t (i64.add
            (i64.add
              (i64.extend_i32_u (array.get $Limbs (local.get $r)
                                          (i32.add (local.get $i) (local.get $j))))
              (i64.mul (local.get $ai)
                       (i64.extend_i32_u (array.get $Limbs (local.get $b) (local.get $j)))))
            (local.get $acarreo)))
          (array.set $Limbs (local.get $r) (i32.add (local.get $i) (local.get $j))
                     (i32.wrap_i64 (local.get $t)))
          (local.set $acarreo (i64.shr_u (local.get $t) (i64.const 32)))
          (local.set $j (i32.add (local.get $j) (i32.const 1)))
          (br $celda)))
      (array.set $Limbs (local.get $r) (i32.add (local.get $i) (local.get $lb))
                 (i32.wrap_i64 (local.get $acarreo)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $fila)))
  (call $limbs_recorta (local.get $r)))

;; --- enteros con signo ---

(func $entero_negado (param $a (ref $Entero)) (result (ref $Entero))
  (if (i32.eqz (array.len (struct.get $Entero $limbs (local.get $a))))
    (then (return (local.get $a))))
  (struct.new $Entero
    (i32.xor (struct.get $Entero $neg (local.get $a)) (i32.const 1))
    (struct.get $Entero $limbs (local.get $a))))

(func $entero_suma (param $a (ref $Entero)) (param $b (ref $Entero)) (result (ref $Entero))
  (local $c i32)
  (if (i32.eq (struct.get $Entero $neg (local.get $a))
              (struct.get $Entero $neg (local.get $b)))
    (then (return (struct.new $Entero
      (struct.get $Entero $neg (local.get $a))
      (call $limbs_suma (struct.get $Entero $limbs (local.get $a))
                        (struct.get $Entero $limbs (local.get $b)))))))
  ;; signos distintos: gana la magnitud mayor
  (local.set $c (call $limbs_compara (struct.get $Entero $limbs (local.get $a))
                                     (struct.get $Entero $limbs (local.get $b))))
  (if (i32.eqz (local.get $c)) (then (return (call $cero))))
  (if (i32.gt_s (local.get $c) (i32.const 0))
    (then (return (struct.new $Entero
      (struct.get $Entero $neg (local.get $a))
      (call $limbs_resta (struct.get $Entero $limbs (local.get $a))
                         (struct.get $Entero $limbs (local.get $b)))))))
  (struct.new $Entero
    (struct.get $Entero $neg (local.get $b))
    (call $limbs_resta (struct.get $Entero $limbs (local.get $b))
                       (struct.get $Entero $limbs (local.get $a)))))

(func $entero_multiplica (param $a (ref $Entero)) (param $b (ref $Entero)) (result (ref $Entero))
  (local $m (ref $Limbs))
  (local.set $m (call $limbs_multiplica (struct.get $Entero $limbs (local.get $a))
                                        (struct.get $Entero $limbs (local.get $b))))
  (if (i32.eqz (array.len (local.get $m))) (then (return (call $cero))))
  (struct.new $Entero
    (i32.xor (struct.get $Entero $neg (local.get $a))
             (struct.get $Entero $neg (local.get $b)))
    (local.get $m)))

;; --- conversiones ---

(func $a_f64 (param $x anyref) (result f64)
  (local $l (ref $Limbs))
  (local $i i32)
  (local $f f64)
  (if (ref.test (ref $Decimal) (local.get $x))
    (then (return (struct.get $Decimal $v (ref.cast (ref $Decimal) (local.get $x))))))
  ;; entero -> f64, del limb alto al bajo (puede redondear: los f64 tienen 53 bits)
  (local.set $l (struct.get $Entero $limbs (ref.cast (ref $Entero) (local.get $x))))
  (local.set $i (array.len (local.get $l)))
  (block $fin
    (loop $baja
      (br_if $fin (i32.eqz (local.get $i)))
      (local.set $i (i32.sub (local.get $i) (i32.const 1)))
      (local.set $f (f64.add
        (f64.mul (local.get $f) (f64.const 4294967296))
        (f64.convert_i64_u (i64.extend_i32_u (array.get $Limbs (local.get $l) (local.get $i))))))
      (br $baja)))
  (if (struct.get $Entero $neg (ref.cast (ref $Entero) (local.get $x)))
    (then (return (f64.neg (local.get $f)))))
  (local.get $f))

(func $es_entera (param $v f64) (result i32)
  ;; entera y finita (los infinitos y NaN fallan una de las dos pruebas)
  (i32.and
    (f64.eq (f64.trunc (local.get $v)) (local.get $v))
    (f64.eq (f64.sub (local.get $v) (local.get $v)) (f64.const 0))))

;; f64 entera y finita -> Entero exacto (por mantisa y exponente, sin bucles)
(func $entero_de_f64 (param $v f64) (result (ref $Entero))
  (local $neg i32)
  (local $bits i64)
  (local $exp i32)
  (local $mant i64)
  (local $k i32)
  (local $s i32)
  (local $lo i64)
  (local $hi i64)
  (local $l (ref $Limbs))
  (if (f64.eq (local.get $v) (f64.const 0)) (then (return (call $cero))))
  (local.set $neg (f64.lt (local.get $v) (f64.const 0)))
  (local.set $bits (i64.reinterpret_f64 (f64.abs (local.get $v))))
  (local.set $exp (i32.sub
    (i32.wrap_i64 (i64.and (i64.shr_u (local.get $bits) (i64.const 52)) (i64.const 2047)))
    (i32.const 1075)))
  (local.set $mant (i64.or (i64.and (local.get $bits) (i64.const 4503599627370495))
                           (i64.const 4503599627370496)))
  (if (i32.lt_s (local.get $exp) (i32.const 0))
    (then
      ;; al ser entera, la mantisa acaba en ceros de sobra para este desplazamiento
      (local.set $mant (i64.shr_u (local.get $mant)
                                  (i64.extend_i32_u (i32.sub (i32.const 0) (local.get $exp)))))
      (local.set $exp (i32.const 0))))
  (local.set $k (i32.div_u (local.get $exp) (i32.const 32)))
  (local.set $s (i32.rem_u (local.get $exp) (i32.const 32)))
  (local.set $lo (i64.shl (local.get $mant) (i64.extend_i32_u (local.get $s))))
  (local.set $hi (select
    (i64.const 0)
    (i64.shr_u (local.get $mant) (i64.extend_i32_u (i32.sub (i32.const 64) (local.get $s))))
    (i32.eqz (local.get $s))))
  (local.set $l (array.new $Limbs (i32.const 0) (i32.add (local.get $k) (i32.const 3))))
  (array.set $Limbs (local.get $l) (local.get $k) (i32.wrap_i64 (local.get $lo)))
  (array.set $Limbs (local.get $l) (i32.add (local.get $k) (i32.const 1))
             (i32.wrap_i64 (i64.shr_u (local.get $lo) (i64.const 32))))
  (array.set $Limbs (local.get $l) (i32.add (local.get $k) (i32.const 2))
             (i32.wrap_i64 (local.get $hi)))
  (struct.new $Entero (local.get $neg) (call $limbs_recorta (local.get $l))))

;; --- enseñar valores (espec §6): entero -> dígitos decimales ---

(func $entero_a_texto (param $e (ref $Entero)) (result (ref $Texto))
  (local $mag (ref $Limbs))
  (local $n i32)
  (local $i i32)
  (local $acc i64)
  (local $resto i64)
  (local $buf (ref $Texto))
  (local $pos i32)
  (local $d i32)
  (local $minimo i32)
  (local $out (ref $Texto))
  (local $largo i32)
  (local.set $n (array.len (struct.get $Entero $limbs (local.get $e))))
  (if (i32.eqz (local.get $n))
    (then (return (array.new_fixed $Texto 1 (i32.const 48)))))
  ;; copia de trabajo de la magnitud (se divide en el sitio)
  (local.set $mag (array.new $Limbs (i32.const 0) (local.get $n)))
  (array.copy $Limbs $Limbs (local.get $mag) (i32.const 0)
              (struct.get $Entero $limbs (local.get $e)) (i32.const 0) (local.get $n))
  ;; buffer generoso: 10 dígitos por limb, más el signo
  (local.set $pos (i32.add (i32.mul (local.get $n) (i32.const 10)) (i32.const 2)))
  (local.set $buf (array.new $Texto (i32.const 0) (local.get $pos)))
  (loop $grupos
    ;; divide la magnitud entre 10^9 en el sitio; el resto son 9 dígitos
    (local.set $resto (i64.const 0))
    (local.set $i (local.get $n))
    (block $fin_div
      (loop $div
        (br_if $fin_div (i32.eqz (local.get $i)))
        (local.set $i (i32.sub (local.get $i) (i32.const 1)))
        (local.set $acc (i64.or
          (i64.shl (local.get $resto) (i64.const 32))
          (i64.extend_i32_u (array.get $Limbs (local.get $mag) (local.get $i)))))
        (array.set $Limbs (local.get $mag) (local.get $i)
                   (i32.wrap_i64 (i64.div_u (local.get $acc) (i64.const 1000000000))))
        (local.set $resto (i64.rem_u (local.get $acc) (i64.const 1000000000)))
        (br $div)))
    (block $fin_recorte
      (loop $recorte
        (br_if $fin_recorte (i32.eqz (local.get $n)))
        (br_if $fin_recorte (i32.ne (array.get $Limbs (local.get $mag)
                                       (i32.sub (local.get $n) (i32.const 1)))
                                    (i32.const 0)))
        (local.set $n (i32.sub (local.get $n) (i32.const 1)))
        (br $recorte)))
    ;; escribe el grupo: 9 dígitos con ceros si queda número, los justos si no
    (local.set $d (i32.wrap_i64 (local.get $resto)))
    (local.set $minimo (select (i32.const 9) (i32.const 1)
                               (i32.gt_u (local.get $n) (i32.const 0))))
    (loop $digitos
      (local.set $pos (i32.sub (local.get $pos) (i32.const 1)))
      (array.set $Texto (local.get $buf) (local.get $pos)
                 (i32.add (i32.const 48) (i32.rem_u (local.get $d) (i32.const 10))))
      (local.set $d (i32.div_u (local.get $d) (i32.const 10)))
      (local.set $minimo (i32.sub (local.get $minimo) (i32.const 1)))
      (br_if $digitos (i32.or (i32.gt_s (local.get $minimo) (i32.const 0))
                              (i32.ne (local.get $d) (i32.const 0)))))
    (br_if $grupos (i32.gt_u (local.get $n) (i32.const 0))))
  (if (struct.get $Entero $neg (local.get $e))
    (then
      (local.set $pos (i32.sub (local.get $pos) (i32.const 1)))
      (array.set $Texto (local.get $buf) (local.get $pos) (i32.const 45))))
  (local.set $largo (i32.sub (array.len (local.get $buf)) (local.get $pos)))
  (local.set $out (array.new $Texto (i32.const 0) (local.get $largo)))
  (array.copy $Texto $Texto (local.get $out) (i32.const 0)
              (local.get $buf) (local.get $pos) (local.get $largo))
  (local.get $out))

(func $mostrar (param $x anyref) (result (ref $Texto))
  (local $v f64)
  ;; nada (null) y booleanos (i31), en el idioma del programa
  (if (ref.is_null (local.get $x))
    (then (return (array.new_data $Texto $msg_nada
                   (i32.const 0) (i32.const 4)))))
  (if (ref.test (ref i31) (local.get $x))
    (then
      (if (i31.get_s (ref.cast (ref i31) (local.get $x)))
        (then (return (array.new_data $Texto $msg_verdadero
                       (i32.const 0) (i32.const 9)))))
      (return (array.new_data $Texto $msg_falso
               (i32.const 0) (i32.const 5)))))
  (if (ref.test (ref $Texto) (local.get $x))
    (then (return (ref.cast (ref $Texto) (local.get $x)))))
  (if (ref.test (ref $Lista) (local.get $x))
    (then (return (call $lista_a_texto (ref.cast (ref $Lista) (local.get $x))))))
  (if (ref.test (ref $Tarjeta) (local.get $x))
    (then (return (call $tarjeta_a_texto (ref.cast (ref $Tarjeta) (local.get $x))))))
  (if (ref.test (ref $Entero) (local.get $x))
    (then (return (call $entero_a_texto (ref.cast (ref $Entero) (local.get $x))))))
  (if (ref.test (ref $Decimal) (local.get $x))
    (then
      (local.set $v (struct.get $Decimal $v (ref.cast (ref $Decimal) (local.get $x))))
      (if (call $es_entera (local.get $v))
        (then (return (call $entero_a_texto (call $entero_de_f64 (local.get $v))))))
      (return (call $decimal_a_texto (local.get $v)))))
  (unreachable))

;; --- decimales con parte fraccionaria: los dígitos justos, como Python ---
;; Steele & White (Dragon4) sobre el bignum: R/S es el valor, mm/mp los
;; medios pasos hasta los f64 vecinos. Se emiten dígitos hasta que la cadena
;; identifica al número sin dudas (leerla de vuelta devuelve el mismo f64).

(func $limbs_de_i64 (param $v i64) (result (ref $Limbs))
  (call $limbs_recorta (array.new_fixed $Limbs 2
    (i32.wrap_i64 (local.get $v))
    (i32.wrap_i64 (i64.shr_u (local.get $v) (i64.const 32))))))

(func $limbs_potencia2 (param $k i32) (result (ref $Limbs))
  (local $r (ref $Limbs))
  (local.set $r (array.new $Limbs (i32.const 0)
                 (i32.add (i32.div_u (local.get $k) (i32.const 32)) (i32.const 1))))
  (array.set $Limbs (local.get $r) (i32.div_u (local.get $k) (i32.const 32))
             (i32.shl (i32.const 1) (i32.rem_u (local.get $k) (i32.const 32))))
  (local.get $r))

(func $decimal_a_texto (param $v f64) (result (ref $Texto))
  (local $neg i32)
  (local $bits i64)
  (local $biased i32)
  (local $f i64)
  (local $e i32)
  (local $even i32)
  (local $R (ref null $Limbs))
  (local $S (ref null $Limbs))
  (local $mp (ref null $Limbs))
  (local $mm (ref null $Limbs))
  (local $k i32)
  (local $digs (ref null $Texto))
  (local $nd i32)
  (local $d i32)
  (local $bajo i32)
  (local $alto i32)
  (local $out (ref null $Texto))
  (local $pos i32)
  (local $j i32)
  (local $m i32)
  (local $r (ref $Texto))
  ;; infinitos y nan, como los enseña Python
  (if (f64.ne (local.get $v) (local.get $v))
    (then (return (array.new_fixed $Texto 3
      (i32.const 110) (i32.const 97) (i32.const 110)))))          ;; nan
  (local.set $neg (f64.lt (local.get $v) (f64.const 0)))
  (local.set $v (f64.abs (local.get $v)))
  (if (f64.eq (local.get $v) (f64.mul (local.get $v) (f64.const 2)))
    (then ;; solo el infinito se queda igual al doblarlo (el 0 no llega aquí)
      (if (local.get $neg)
        (then (return (array.new_fixed $Texto 4
          (i32.const 45) (i32.const 105) (i32.const 110) (i32.const 102)))))  ;; -inf
      (return (array.new_fixed $Texto 3
        (i32.const 105) (i32.const 110) (i32.const 102)))))       ;; inf
  (local.set $bits (i64.reinterpret_f64 (local.get $v)))
  (local.set $biased (i32.wrap_i64 (i64.and (i64.shr_u (local.get $bits) (i64.const 52))
                                            (i64.const 2047))))
  (local.set $f (i64.and (local.get $bits) (i64.const 4503599627370495)))
  (if (i32.eqz (local.get $biased))
    (then (local.set $e (i32.const -1074)))                       ;; subnormal
    (else
      (local.set $f (i64.or (local.get $f) (i64.const 4503599627370496)))
      (local.set $e (i32.sub (local.get $biased) (i32.const 1075)))))
  (local.set $even (i64.eqz (i64.and (local.get $f) (i64.const 1))))
  ;; puesta en escena de R/S y los medios pasos mm/mp
  (if (i32.ge_s (local.get $e) (i32.const 0))
    (then
      (local.set $mp (call $limbs_potencia2 (local.get $e)))
      (local.set $mm (local.get $mp))
      (local.set $R (call $limbs_multiplica (call $limbs_de_i64 (local.get $f))
                          (call $limbs_potencia2 (i32.add (local.get $e) (i32.const 1)))))
      (local.set $S (array.new_fixed $Limbs 1 (i32.const 2))))
    (else
      (local.set $mp (array.new_fixed $Limbs 1 (i32.const 1)))
      (local.set $mm (local.get $mp))
      (local.set $R (call $limbs_multiplica (call $limbs_de_i64 (local.get $f))
                          (array.new_fixed $Limbs 1 (i32.const 2))))
      (local.set $S (call $limbs_potencia2 (i32.sub (i32.const 1) (local.get $e))))))
  ;; la frontera de abajo es más corta justo tras una potencia de dos
  (if (i32.and (i64.eq (local.get $f) (i64.const 4503599627370496))
               (i32.gt_s (local.get $biased) (i32.const 1)))
    (then
      (local.set $R (call $limbs_multiplica (local.get $R)
                          (array.new_fixed $Limbs 1 (i32.const 2))))
      (local.set $S (call $limbs_multiplica (local.get $S)
                          (array.new_fixed $Limbs 1 (i32.const 2))))
      (local.set $mp (call $limbs_multiplica (local.get $mp)
                           (array.new_fixed $Limbs 1 (i32.const 2))))))
  ;; escala hasta que el primer dígito valga (k cuenta el punto decimal)
  (block $fin_baja
    (loop $baja
      (br_if $fin_baja (i32.eqz (call $dragon_alto
        (local.get $R) (local.get $mp) (local.get $S) (local.get $even))))
      (local.set $S (call $limbs_x10_mas (local.get $S) (i32.const 0)))
      (local.set $k (i32.add (local.get $k) (i32.const 1)))
      (br $baja)))
  (block $fin_sube
    (loop $sube
      (br_if $fin_sube (i32.gt_s (call $limbs_compara
        (call $limbs_x10_mas (call $limbs_suma (local.get $R) (local.get $mp)) (i32.const 0))
        (local.get $S)) (i32.const 0)))
      (local.set $R (call $limbs_x10_mas (local.get $R) (i32.const 0)))
      (local.set $mp (call $limbs_x10_mas (local.get $mp) (i32.const 0)))
      (local.set $mm (call $limbs_x10_mas (local.get $mm) (i32.const 0)))
      (local.set $k (i32.sub (local.get $k) (i32.const 1)))
      (br $sube)))
  ;; genera dígitos hasta que la cadena baste
  (local.set $digs (array.new $Texto (i32.const 48) (i32.const 32)))
  (block $fin_digitos
    (loop $digitos
      (local.set $R (call $limbs_x10_mas (local.get $R) (i32.const 0)))
      (local.set $mp (call $limbs_x10_mas (local.get $mp) (i32.const 0)))
      (local.set $mm (call $limbs_x10_mas (local.get $mm) (i32.const 0)))
      (local.set $d (i32.const 0))
      (block $fin_resta
        (loop $resta
          (br_if $fin_resta (i32.lt_s (call $limbs_compara (local.get $R) (local.get $S))
                                      (i32.const 0)))
          (local.set $R (call $limbs_resta (local.get $R) (local.get $S)))
          (local.set $d (i32.add (local.get $d) (i32.const 1)))
          (br $resta)))
      (local.set $bajo (call $dragon_bajo (local.get $R) (local.get $mm) (local.get $even)))
      (local.set $alto (call $dragon_alto
        (local.get $R) (local.get $mp) (local.get $S) (local.get $even)))
      (if (i32.and (i32.eqz (local.get $bajo)) (i32.eqz (local.get $alto)))
        (then ;; aún no basta: apunta el dígito y sigue
          (array.set $Texto (local.get $digs) (i32.add (local.get $nd) (i32.const 1))
                     (i32.add (i32.const 48) (local.get $d)))
          (local.set $nd (i32.add (local.get $nd) (i32.const 1)))
          (br $digitos)))
      ;; último dígito: redondea al vecino más cercano
      (if (i32.and (local.get $alto) (i32.or (i32.eqz (local.get $bajo))
            (i32.ge_s (call $limbs_compara
              (call $limbs_suma (local.get $R) (local.get $R)) (local.get $S))
              (i32.const 0))))
        (then (local.set $d (i32.add (local.get $d) (i32.const 1)))))
      (array.set $Texto (local.get $digs) (i32.add (local.get $nd) (i32.const 1))
                 (i32.add (i32.const 48) (local.get $d)))
      (local.set $nd (i32.add (local.get $nd) (i32.const 1)))))
  ;; el redondeo puede desbordar en cadena (…9 -> 10): acarrea hacia delante
  (local.set $j (local.get $nd))
  (block $fin_acarreo
    (loop $acarreo
      (br_if $fin_acarreo (i32.lt_u (array.get_u $Texto (local.get $digs) (local.get $j))
                                    (i32.const 58)))
      (array.set $Texto (local.get $digs) (local.get $j) (i32.const 48))
      (local.set $j (i32.sub (local.get $j) (i32.const 1)))
      (array.set $Texto (local.get $digs) (local.get $j)
                 (i32.add (array.get_u $Texto (local.get $digs) (local.get $j)) (i32.const 1)))
      (br $acarreo)))
  (if (i32.eqz (local.get $j))
    (then ;; el acarreo llegó al principio: el "1" nuevo corre el punto
      (local.set $k (i32.add (local.get $k) (i32.const 1)))
      (local.set $nd (i32.add (local.get $nd) (i32.const 1)))))
  ;; sin acarreo total, los dígitos empiezan en 1; con él, en 0 (el 48+1)
  (local.set $j (select (i32.const 0) (i32.const 1) (i32.eqz (local.get $j))))
  ;; monta el texto: posicional entre 0.0001 y 10^16, científico por debajo
  (local.set $out (array.new $Texto (i32.const 0) (i32.const 64)))
  (if (local.get $neg)
    (then
      (array.set $Texto (local.get $out) (i32.const 0) (i32.const 45))
      (local.set $pos (i32.const 1))))
  (if (i32.lt_s (i32.sub (local.get $k) (i32.const 1)) (i32.const -4))
    (then ;; científico: d.dddde-XX (solo pasa con exponente negativo)
      (array.set $Texto (local.get $out) (local.get $pos)
                 (array.get_u $Texto (local.get $digs) (local.get $j)))
      (local.set $pos (i32.add (local.get $pos) (i32.const 1)))
      (if (i32.gt_s (local.get $nd) (i32.const 1))
        (then
          (array.set $Texto (local.get $out) (local.get $pos) (i32.const 46))
          (local.set $pos (i32.add (local.get $pos) (i32.const 1)))
          (array.copy $Texto $Texto (local.get $out) (local.get $pos)
                      (local.get $digs) (i32.add (local.get $j) (i32.const 1))
                      (i32.sub (local.get $nd) (i32.const 1)))
          (local.set $pos (i32.add (local.get $pos) (i32.sub (local.get $nd) (i32.const 1))))))
      (array.set $Texto (local.get $out) (local.get $pos) (i32.const 101))  ;; e
      (array.set $Texto (local.get $out) (i32.add (local.get $pos) (i32.const 1))
                 (i32.const 45))                                            ;; -
      (local.set $pos (i32.add (local.get $pos) (i32.const 2)))
      (local.set $m (i32.sub (i32.const 1) (local.get $k)))
      (if (i32.ge_s (local.get $m) (i32.const 100))
        (then
          (array.set $Texto (local.get $out) (local.get $pos)
                     (i32.add (i32.const 48) (i32.div_u (local.get $m) (i32.const 100))))
          (local.set $pos (i32.add (local.get $pos) (i32.const 1)))
          (local.set $m (i32.rem_u (local.get $m) (i32.const 100)))))
      (array.set $Texto (local.get $out) (local.get $pos)
                 (i32.add (i32.const 48) (i32.div_u (local.get $m) (i32.const 10))))
      (array.set $Texto (local.get $out) (i32.add (local.get $pos) (i32.const 1))
                 (i32.add (i32.const 48) (i32.rem_u (local.get $m) (i32.const 10))))
      (local.set $pos (i32.add (local.get $pos) (i32.const 2))))
    (else
      (if (i32.le_s (local.get $k) (i32.const 0))
        (then ;; 0.00ddd
          (array.set $Texto (local.get $out) (local.get $pos) (i32.const 48))
          (array.set $Texto (local.get $out) (i32.add (local.get $pos) (i32.const 1))
                     (i32.const 46))
          (local.set $pos (i32.add (local.get $pos) (i32.const 2)))
          (local.set $m (i32.const 0))
          (block $fin_ceros
            (loop $ceros
              (br_if $fin_ceros (i32.ge_s (local.get $m)
                                          (i32.sub (i32.const 0) (local.get $k))))
              (array.set $Texto (local.get $out) (local.get $pos) (i32.const 48))
              (local.set $pos (i32.add (local.get $pos) (i32.const 1)))
              (local.set $m (i32.add (local.get $m) (i32.const 1)))
              (br $ceros)))
          (array.copy $Texto $Texto (local.get $out) (local.get $pos)
                      (local.get $digs) (local.get $j) (local.get $nd))
          (local.set $pos (i32.add (local.get $pos) (local.get $nd))))
        (else ;; ddd.ddd (k < nd siempre: el valor no es entero)
          (array.copy $Texto $Texto (local.get $out) (local.get $pos)
                      (local.get $digs) (local.get $j) (local.get $k))
          (local.set $pos (i32.add (local.get $pos) (local.get $k)))
          (array.set $Texto (local.get $out) (local.get $pos) (i32.const 46))
          (local.set $pos (i32.add (local.get $pos) (i32.const 1)))
          (array.copy $Texto $Texto (local.get $out) (local.get $pos)
                      (local.get $digs) (i32.add (local.get $j) (local.get $k))
                      (i32.sub (local.get $nd) (local.get $k)))
          (local.set $pos (i32.add (local.get $pos)
                                   (i32.sub (local.get $nd) (local.get $k))))))))
  (local.set $r (array.new $Texto (i32.const 0) (local.get $pos)))
  (array.copy $Texto $Texto (local.get $r) (i32.const 0)
              (local.get $out) (i32.const 0) (local.get $pos))
  (local.get $r))

;; ¿la cadena ya se pasa por arriba? (con mantisa par la frontera cuenta)
(func $dragon_alto (param $R (ref null $Limbs)) (param $mp (ref null $Limbs))
                   (param $S (ref null $Limbs)) (param $even i32) (result i32)
  (local $c i32)
  (local.set $c (call $limbs_compara (call $limbs_suma (local.get $R) (local.get $mp))
                                     (local.get $S)))
  (select (i32.ge_s (local.get $c) (i32.const 0))
          (i32.gt_s (local.get $c) (i32.const 0))
          (local.get $even)))

;; ¿la cadena ya se queda por abajo?
(func $dragon_bajo (param $R (ref null $Limbs)) (param $mm (ref null $Limbs))
                   (param $even i32) (result i32)
  (local $c i32)
  (local.set $c (call $limbs_compara (local.get $R) (local.get $mm)))
  (select (i32.le_s (local.get $c) (i32.const 0))
          (i32.lt_s (local.get $c) (i32.const 0))
          (local.get $even)))

;; --- las cuatro operaciones, sobre cualquier número (espec §6) ---
;; entero (op) entero conserva la precisión ilimitada; si entra un decimal,
;; se calcula en f64, como hace el intérprete con los float de Python.

(func $ambos_enteros (param $a anyref) (param $b anyref) (result i32)
  (i32.and (ref.test (ref $Entero) (local.get $a))
           (ref.test (ref $Entero) (local.get $b))))

(func $num_suma (param $a anyref) (param $b anyref) (result anyref)
  (if (call $ambos_enteros (local.get $a) (local.get $b))
    (then (return (call $entero_suma (ref.cast (ref $Entero) (local.get $a))
                                     (ref.cast (ref $Entero) (local.get $b))))))
  (struct.new $Decimal (f64.add (call $a_f64 (local.get $a))
                                (call $a_f64 (local.get $b)))))

(func $num_resta (param $a anyref) (param $b anyref) (result anyref)
  (if (call $ambos_enteros (local.get $a) (local.get $b))
    (then (return (call $entero_suma
      (ref.cast (ref $Entero) (local.get $a))
      (call $entero_negado (ref.cast (ref $Entero) (local.get $b)))))))
  (struct.new $Decimal (f64.sub (call $a_f64 (local.get $a))
                                (call $a_f64 (local.get $b)))))

(func $num_multiplica (param $a anyref) (param $b anyref) (result anyref)
  (if (call $ambos_enteros (local.get $a) (local.get $b))
    (then (return (call $entero_multiplica (ref.cast (ref $Entero) (local.get $a))
                                           (ref.cast (ref $Entero) (local.get $b))))))
  (struct.new $Decimal (f64.mul (call $a_f64 (local.get $a))
                                (call $a_f64 (local.get $b)))))

;; dividir siempre da decimal (como en Python); entre cero es error amable
(func $num_divide (param $a anyref) (param $b anyref) (result anyref)
  (local $db f64)
  (local.set $db (call $a_f64 (local.get $b)))
  (if (f64.eq (local.get $db) (f64.const 0))
    (then
      (call $panico (array.new_data $Texto $msg_div0
                     (i32.const 0) (i32.const 38)))
      (unreachable)))
  (struct.new $Decimal (f64.div (call $a_f64 (local.get $a)) (local.get $db))))

(func $num_negado (param $a anyref) (result anyref)
  (if (ref.test (ref $Entero) (local.get $a))
    (then (return (call $entero_negado (ref.cast (ref $Entero) (local.get $a))))))
  (struct.new $Decimal (f64.neg (call $a_f64 (local.get $a)))))

;; --- condiciones, comparaciones e igualdad (espec §6) ---

;; error amable con el valor culpable en medio: "...aquí vale {valor}."
(func $panico_condicion (param $x anyref)
  (call $panico (call $concatenar (call $concatenar
    (array.new_data $Texto $msg_cond_pre (i32.const 0) (i32.const 67))
    (call $mostrar (local.get $x)))
    (array.new_data $Texto $msg_cond_post (i32.const 0) (i32.const 1)))))

(func $panico_entero (param $x anyref)
  (call $panico (call $concatenar (call $concatenar
    (array.new_data $Texto $msg_entero_pre (i32.const 0) (i32.const 50))
    (call $mostrar (local.get $x)))
    (array.new_data $Texto $msg_entero_post (i32.const 0) (i32.const 1)))))

;; la condición debe ser un booleano de verdad, como exige el intérprete
(func $verdad (param $x anyref) (result i32)
  (if (ref.test (ref i31) (local.get $x))
    (then (return (i31.get_s (ref.cast (ref i31) (local.get $x))))))
  (call $panico_condicion (local.get $x))
  (unreachable))

;; exige un entero (o un decimal sin parte fraccionaria, que se convierte)
(func $a_entero (param $x anyref) (result (ref $Entero))
  (local $v f64)
  (if (ref.test (ref $Entero) (local.get $x))
    (then (return (ref.cast (ref $Entero) (local.get $x)))))
  (if (ref.test (ref $Decimal) (local.get $x))
    (then
      (local.set $v (struct.get $Decimal $v (ref.cast (ref $Decimal) (local.get $x))))
      (if (call $es_entera (local.get $v))
        (then (return (call $entero_de_f64 (local.get $v)))))))
  (call $panico_entero (local.get $x))
  (unreachable))

(func $uno (result (ref $Entero))
  (struct.new $Entero (i32.const 0) (array.new_fixed $Limbs 1 (i32.const 1))))

;; para los bucles: ¿el contador (un entero) sigue por encima de cero?
(func $es_positivo (param $x anyref) (result i32)
  (local $e (ref null $Entero))
  (local.set $e (ref.cast (ref $Entero) (local.get $x)))
  (i32.and
    (i32.eqz (struct.get $Entero $neg (local.get $e)))
    (i32.gt_u (array.len (struct.get $Entero $limbs (local.get $e))) (i32.const 0))))

;; compara dos números: -1, 0 o 1; entero contra entero es exacto
(func $num_compara (param $a anyref) (param $b anyref) (result i32)
  (local $ea (ref null $Entero))
  (local $eb (ref null $Entero))
  (local $c i32)
  (local $fa f64)
  (local $fb f64)
  (if (call $ambos_enteros (local.get $a) (local.get $b))
    (then
      (local.set $ea (ref.cast (ref $Entero) (local.get $a)))
      (local.set $eb (ref.cast (ref $Entero) (local.get $b)))
      (if (i32.ne (struct.get $Entero $neg (local.get $ea))
                  (struct.get $Entero $neg (local.get $eb)))
        (then (return (select (i32.const -1) (i32.const 1)
                              (struct.get $Entero $neg (local.get $ea))))))
      (local.set $c (call $limbs_compara
        (struct.get $Entero $limbs (local.get $ea))
        (struct.get $Entero $limbs (local.get $eb))))
      (if (struct.get $Entero $neg (local.get $ea))
        (then (return (i32.sub (i32.const 0) (local.get $c)))))
      (return (local.get $c))))
  (local.set $fa (call $a_f64 (local.get $a)))
  (local.set $fb (call $a_f64 (local.get $b)))
  (if (f64.lt (local.get $fa) (local.get $fb)) (then (return (i32.const -1))))
  (if (f64.gt (local.get $fa) (local.get $fb)) (then (return (i32.const 1))))
  (i32.const 0))

(func $enteros_iguales (param $a (ref $Entero)) (param $b (ref $Entero)) (result i32)
  (i32.and
    (i32.eq (struct.get $Entero $neg (local.get $a))
            (struct.get $Entero $neg (local.get $b)))
    (i32.eqz (call $limbs_compara (struct.get $Entero $limbs (local.get $a))
                                  (struct.get $Entero $limbs (local.get $b))))))

;; entero contra decimal: iguales solo si el decimal es entero y coincide exacto
(func $entero_decimal_iguales (param $e (ref $Entero)) (param $v f64) (result i32)
  (if (i32.eqz (call $es_entera (local.get $v))) (then (return (i32.const 0))))
  (call $enteros_iguales (local.get $e) (call $entero_de_f64 (local.get $v))))

(func $textos_iguales (param $a (ref $Texto)) (param $b (ref $Texto)) (result i32)
  (local $n i32)
  (local $i i32)
  (local.set $n (array.len (local.get $a)))
  (if (i32.ne (local.get $n) (array.len (local.get $b)))
    (then (return (i32.const 0))))
  (block $fin
    (loop $sigue
      (br_if $fin (i32.ge_u (local.get $i) (local.get $n)))
      (if (i32.ne (array.get_u $Texto (local.get $a) (local.get $i))
                  (array.get_u $Texto (local.get $b) (local.get $i)))
        (then (return (i32.const 0))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $sigue)))
  (i32.const 1))

;; igualdad de Anlaco: tipos distintos dan falso, salvo entero contra decimal
(func $iguales (param $a anyref) (param $b anyref) (result i32)
  (if (i32.and (ref.is_null (local.get $a)) (ref.is_null (local.get $b)))
    (then (return (i32.const 1))))
  (if (i32.or (ref.is_null (local.get $a)) (ref.is_null (local.get $b)))
    (then (return (i32.const 0))))
  ;; un booleano solo es igual a otro booleano
  (if (i32.ne (ref.test (ref i31) (local.get $a)) (ref.test (ref i31) (local.get $b)))
    (then (return (i32.const 0))))
  (if (ref.test (ref i31) (local.get $a))
    (then (return (i32.eq (i31.get_s (ref.cast (ref i31) (local.get $a)))
                          (i31.get_s (ref.cast (ref i31) (local.get $b)))))))
  (if (call $ambos_enteros (local.get $a) (local.get $b))
    (then (return (call $enteros_iguales (ref.cast (ref $Entero) (local.get $a))
                                         (ref.cast (ref $Entero) (local.get $b))))))
  (if (i32.and (ref.test (ref $Decimal) (local.get $a))
               (ref.test (ref $Decimal) (local.get $b)))
    (then (return (f64.eq (struct.get $Decimal $v (ref.cast (ref $Decimal) (local.get $a)))
                          (struct.get $Decimal $v (ref.cast (ref $Decimal) (local.get $b)))))))
  (if (i32.and (ref.test (ref $Entero) (local.get $a))
               (ref.test (ref $Decimal) (local.get $b)))
    (then (return (call $entero_decimal_iguales
      (ref.cast (ref $Entero) (local.get $a))
      (struct.get $Decimal $v (ref.cast (ref $Decimal) (local.get $b)))))))
  (if (i32.and (ref.test (ref $Decimal) (local.get $a))
               (ref.test (ref $Entero) (local.get $b)))
    (then (return (call $entero_decimal_iguales
      (ref.cast (ref $Entero) (local.get $b))
      (struct.get $Decimal $v (ref.cast (ref $Decimal) (local.get $a)))))))
  (if (i32.and (ref.test (ref $Texto) (local.get $a))
               (ref.test (ref $Texto) (local.get $b)))
    (then (return (call $textos_iguales (ref.cast (ref $Texto) (local.get $a))
                                        (ref.cast (ref $Texto) (local.get $b))))))
  (if (i32.and (ref.test (ref $Lista) (local.get $a))
               (ref.test (ref $Lista) (local.get $b)))
    (then (return (call $listas_iguales (ref.cast (ref $Lista) (local.get $a))
                                        (ref.cast (ref $Lista) (local.get $b))))))
  (if (i32.and (ref.test (ref $Tarjeta) (local.get $a))
               (ref.test (ref $Tarjeta) (local.get $b)))
    (then (return (call $tarjetas_iguales (ref.cast (ref $Tarjeta) (local.get $a))
                                          (ref.cast (ref $Tarjeta) (local.get $b))))))
  (i32.const 0))

;; --- la respuesta a "...": preguntar y leer del teclado ---

;; lee una línea de la entrada, byte a byte; sin nada que leer es error
(func $leer_linea (result (ref $Texto))
  (local $n i32)
  (local $leidos i32)
  (local $byte i32)
  (local $r (ref $Texto))
  (local $i i32)
  (block $fin_linea
    (loop $lee
      ;; sitio para el byte: 16 + n (pide otra página si hace falta)
      (block $cabe
        (br_if $cabe (i32.lt_u (i32.add (local.get $n) (i32.const 32))
                               (i32.mul (memory.size) (i32.const 65536))))
        (drop (memory.grow (i32.const 1))))
      (i32.store (i32.const 0) (i32.add (i32.const 16) (local.get $n)))
      (i32.store (i32.const 4) (i32.const 1))
      (drop (call $fd_read (i32.const 0) (i32.const 0) (i32.const 1) (i32.const 8)))
      (local.set $leidos (i32.load (i32.const 8)))
      (br_if $fin_linea (i32.eqz (local.get $leidos)))
      (local.set $byte (i32.load8_u (i32.add (i32.const 16) (local.get $n))))
      (br_if $fin_linea (i32.eq (local.get $byte) (i32.const 10)))
      (local.set $n (i32.add (local.get $n) (i32.const 1)))
      (br $lee)))
  ;; sin un solo byte y sin salto: el programa esperaba una respuesta
  (if (i32.and (i32.eqz (local.get $n)) (i32.eqz (local.get $leidos)))
    (then
      (call $panico (array.new_data $Texto $msg_sin_respuesta
                     (i32.const 0) (i32.const 62)))
      (unreachable)))
  (local.set $r (array.new $Texto (i32.const 0) (local.get $n)))
  (block $fin_copia
    (loop $copia
      (br_if $fin_copia (i32.ge_u (local.get $i) (local.get $n)))
      (array.set $Texto (local.get $r) (local.get $i)
                 (i32.load8_u (i32.add (i32.const 16) (local.get $i))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $copia)))
  (local.get $r))

;; magnitud por diez más un dígito, en una pasada (para leer números)
(func $limbs_x10_mas (param $a (ref null $Limbs)) (param $d i32) (result (ref $Limbs))
  (local $la i32)
  (local $i i32)
  (local $t i64)
  (local $acarreo i64)
  (local $r (ref $Limbs))
  (local.set $la (array.len (local.get $a)))
  (local.set $r (array.new $Limbs (i32.const 0) (i32.add (local.get $la) (i32.const 1))))
  (local.set $acarreo (i64.extend_i32_u (local.get $d)))
  (block $fin
    (loop $sigue
      (br_if $fin (i32.ge_u (local.get $i) (local.get $la)))
      (local.set $t (i64.add
        (i64.mul (i64.extend_i32_u (array.get $Limbs (local.get $a) (local.get $i)))
                 (i64.const 10))
        (local.get $acarreo)))
      (array.set $Limbs (local.get $r) (local.get $i) (i32.wrap_i64 (local.get $t)))
      (local.set $acarreo (i64.shr_u (local.get $t) (i64.const 32)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $sigue)))
  (array.set $Limbs (local.get $r) (local.get $la) (i32.wrap_i64 (local.get $acarreo)))
  (call $limbs_recorta (local.get $r)))

;; clasifica la respuesta como hace el intérprete: -?dígitos -> entero,
;; -?dígitos.dígitos -> decimal, cualquier otra cosa -> texto
(func $texto_a_valor (param $t (ref $Texto)) (result anyref)
  (local $n i32)
  (local $i i32)
  (local $neg i32)
  (local $byte i32)
  (local $enteros i32)
  (local $decimales i32)
  (local $mag (ref $Limbs))
  (local $k i32)
  (local $divisor f64)
  (local.set $n (array.len (local.get $t)))
  (if (i32.eqz (local.get $n)) (then (return (local.get $t))))
  (if (i32.eq (array.get_u $Texto (local.get $t) (i32.const 0)) (i32.const 45))
    (then
      (local.set $neg (i32.const 1))
      (local.set $i (i32.const 1))))
  (local.set $mag (array.new_fixed $Limbs 0))
  ;; parte entera
  (block $fin_enteros
    (loop $entero
      (br_if $fin_enteros (i32.ge_u (local.get $i) (local.get $n)))
      (local.set $byte (array.get_u $Texto (local.get $t) (local.get $i)))
      (br_if $fin_enteros (i32.or (i32.lt_u (local.get $byte) (i32.const 48))
                                  (i32.gt_u (local.get $byte) (i32.const 57))))
      (local.set $mag (call $limbs_x10_mas (local.get $mag)
                            (i32.sub (local.get $byte) (i32.const 48))))
      (local.set $enteros (i32.add (local.get $enteros) (i32.const 1)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $entero)))
  (if (i32.eqz (local.get $enteros)) (then (return (local.get $t))))
  (if (i32.eq (local.get $i) (local.get $n))
    (then
      (if (i32.eqz (array.len (local.get $mag)))
        (then (return (call $cero))))
      (return (struct.new $Entero (local.get $neg) (local.get $mag)))))
  ;; parte decimal: exige un punto y al menos un dígito hasta el final
  (if (i32.ne (array.get_u $Texto (local.get $t) (local.get $i)) (i32.const 46))
    (then (return (local.get $t))))
  (local.set $i (i32.add (local.get $i) (i32.const 1)))
  (block $fin_decimales
    (loop $decimal
      (br_if $fin_decimales (i32.ge_u (local.get $i) (local.get $n)))
      (local.set $byte (array.get_u $Texto (local.get $t) (local.get $i)))
      (br_if $fin_decimales (i32.or (i32.lt_u (local.get $byte) (i32.const 48))
                                    (i32.gt_u (local.get $byte) (i32.const 57))))
      (local.set $mag (call $limbs_x10_mas (local.get $mag)
                            (i32.sub (local.get $byte) (i32.const 48))))
      (local.set $decimales (i32.add (local.get $decimales) (i32.const 1)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $decimal)))
  (if (i32.or (i32.eqz (local.get $decimales)) (i32.ne (local.get $i) (local.get $n)))
    (then (return (local.get $t))))
  ;; todos los dígitos juntos entre 10^decimales (puede redondear el último bit)
  (local.set $divisor (f64.const 1))
  (local.set $k (local.get $decimales))
  (block $fin_potencia
    (loop $potencia
      (br_if $fin_potencia (i32.eqz (local.get $k)))
      (local.set $divisor (f64.mul (local.get $divisor) (f64.const 10)))
      (local.set $k (i32.sub (local.get $k) (i32.const 1)))
      (br $potencia)))
  (struct.new $Decimal (f64.div
    (call $a_f64 (struct.new $Entero (local.get $neg) (local.get $mag)))
    (local.get $divisor))))

;; la respuesta a P: enseña la pregunta y devuelve la línea, ya clasificada
(func $respuesta (param $pregunta anyref) (result anyref)
  (call $escribe (call $mostrar (local.get $pregunta)))
  (call $texto_a_valor (call $leer_linea)))

;; --- llamadas a funciones: la espec §6 garantiza 1000 de profundidad ---

(global $profundidad (mut i32) (i32.const 0))

(func $entra_llamada
  (global.set $profundidad (i32.add (global.get $profundidad) (i32.const 1)))
  (if (i32.gt_s (global.get $profundidad) (i32.const 1000))
    (then (call $panico (array.new_data $Texto $msg_llamadas
                         (i32.const 0) (i32.const 102))))))

(func $sale_llamada
  (global.set $profundidad (i32.sub (global.get $profundidad) (i32.const 1))))

;; --- listas: crecen por dentro, se comparten por referencia ---

(func $lista_nueva (result (ref $Lista))
  (struct.new $Lista (i32.const 0) (array.new $Items (ref.null any) (i32.const 4))))

;; añade al final (devuelve la misma lista, para poder encadenar literales)
(func $lista_anade (param $l (ref $Lista)) (param $x anyref) (result (ref $Lista))
  (local $n i32)
  (local $items (ref $Items))
  (local $nuevos (ref $Items))
  (local.set $n (struct.get $Lista $n (local.get $l)))
  (local.set $items (struct.get $Lista $items (local.get $l)))
  ;; sin sitio: array nuevo del doble y se copia lo que había
  (if (i32.ge_u (local.get $n) (array.len (local.get $items)))
    (then
      (local.set $nuevos (array.new $Items (ref.null any)
                          (i32.mul (array.len (local.get $items)) (i32.const 2))))
      (array.copy $Items $Items (local.get $nuevos) (i32.const 0)
                  (local.get $items) (i32.const 0) (local.get $n))
      (struct.set $Lista $items (local.get $l) (local.get $nuevos))
      (local.set $items (local.get $nuevos))))
  (array.set $Items (local.get $items) (local.get $n) (local.get $x))
  (struct.set $Lista $n (local.get $l) (i32.add (local.get $n) (i32.const 1)))
  (local.get $l))

;; exige una colección (lista, o texto que se vuelve su lista de letras),
;; con el error amable del intérprete
(func $a_lista (param $x anyref) (result (ref $Lista))
  (if (ref.test (ref $Lista) (local.get $x))
    (then (return (ref.cast (ref $Lista) (local.get $x)))))
  (if (ref.test (ref $Texto) (local.get $x))
    (then (return (call $texto_a_lista (ref.cast (ref $Texto) (local.get $x))))))
  (call $panico (call $concatenar (call $concatenar
    (array.new_data $Texto $msg_lista_pre (i32.const 0) (i32.const 53))
    (call $mostrar (local.get $x)))
    (array.new_data $Texto $msg_lista_post (i32.const 0) (i32.const 1))))
  (unreachable))

(func $entero_de_i32 (param $v i32) (result (ref $Entero))
  (if (i32.eqz (local.get $v)) (then (return (call $cero))))
  (if (i32.lt_s (local.get $v) (i32.const 0))
    (then (return (struct.new $Entero (i32.const 1)
      (array.new_fixed $Limbs 1 (i32.sub (i32.const 0) (local.get $v)))))))
  (struct.new $Entero (i32.const 0) (array.new_fixed $Limbs 1 (local.get $v))))

;; elemento I de L: el índice empieza en 1, como cuenta una persona
(func $lista_elemento (param $x anyref) (param $indice anyref) (result anyref)
  (local $l (ref null $Lista))
  (local $i f64)
  (local $n i32)
  (local $pos i32)
  (if (ref.test (ref $Texto) (local.get $x))
    (then (return (call $texto_elemento
                   (ref.cast (ref $Texto) (local.get $x)) (local.get $indice)))))
  (local.set $l (call $a_lista (local.get $x)))
  (local.set $n (struct.get $Lista $n (local.get $l)))
  (local.set $i (call $a_f64 (call $a_entero (local.get $indice))))
  ;; fuera de la lista: "La lista tiene N elementos y pediste el I."
  (if (i32.or (f64.lt (local.get $i) (f64.const 1))
              (f64.gt (local.get $i) (f64.convert_i32_s (local.get $n))))
    (then
      (call $panico (call $concatenar (call $concatenar (call $concatenar (call $concatenar
        (array.new_data $Texto $msg_indice_pre (i32.const 0) (i32.const 22))
        (call $entero_a_texto (call $entero_de_i32 (local.get $n))))
        (array.new_data $Texto $msg_indice_mid (i32.const 0) (i32.const 24)))
        (call $mostrar (call $a_entero (local.get $indice))))
        (array.new_data $Texto $msg_indice_post (i32.const 0) (i32.const 1))))
      (unreachable)))
  (local.set $pos (i32.trunc_f64_s (local.get $i)))
  (array.get $Items (struct.get $Lista $items (local.get $l))
             (i32.sub (local.get $pos) (i32.const 1))))

(func $lista_primero (param $x anyref) (result anyref)
  (local $l (ref null $Lista))
  (if (ref.test (ref $Texto) (local.get $x))
    (then
      (if (i32.eqz (array.len (ref.cast (ref $Texto) (local.get $x))))
        (then
          (call $panico (array.new_data $Texto $msg_texto_vacio_primero
                         (i32.const 0) (i32.const 53)))
          (unreachable)))))
  (local.set $l (call $a_lista (local.get $x)))
  (if (i32.eqz (struct.get $Lista $n (local.get $l)))
    (then
      (call $panico (array.new_data $Texto $msg_vacia_primero
                     (i32.const 0) (i32.const 47)))
      (unreachable)))
  (array.get $Items (struct.get $Lista $items (local.get $l)) (i32.const 0)))

(func $lista_ultimo (param $x anyref) (result anyref)
  (local $l (ref null $Lista))
  (if (ref.test (ref $Texto) (local.get $x))
    (then
      (if (i32.eqz (array.len (ref.cast (ref $Texto) (local.get $x))))
        (then
          (call $panico (array.new_data $Texto $msg_texto_vacio_ultimo
                         (i32.const 0) (i32.const 53)))
          (unreachable)))))
  (local.set $l (call $a_lista (local.get $x)))
  (if (i32.eqz (struct.get $Lista $n (local.get $l)))
    (then
      (call $panico (array.new_data $Texto $msg_vacia_ultimo
                     (i32.const 0) (i32.const 47)))
      (unreachable)))
  (array.get $Items (struct.get $Lista $items (local.get $l))
             (i32.sub (struct.get $Lista $n (local.get $l)) (i32.const 1))))

(func $lista_cantidad (param $x anyref) (result anyref)
  (call $entero_de_i32 (struct.get $Lista $n (call $a_lista (local.get $x)))))

;; --- textos como listas de letras (v0.2): cada letra es un texto de 1 carácter ---

;; los bytes [desde, desde+largo) como texto nuevo
(func $texto_trozo (param $t (ref $Texto)) (param $desde i32) (param $largo i32)
      (result (ref $Texto))
  (local $r (ref null $Texto))
  (local.set $r (array.new $Texto (i32.const 0) (local.get $largo)))
  (array.copy $Texto $Texto (local.get $r) (i32.const 0)
              (local.get $t) (local.get $desde) (local.get $largo))
  (ref.as_non_null (local.get $r)))

;; ¿es este texto el que guarda el hueco? (identidad de objeto)
(func $c_acierta (param $guardado anyref) (param $t (ref $Texto)) (result i32)
  (if (i32.eqz (ref.test (ref $Texto) (local.get $guardado)))
    (then (return (i32.const 0))))
  (ref.eq (ref.cast (ref $Texto) (local.get $guardado)) (local.get $t)))

;; la lista de letras: se anda el UTF-8 (una letra = un byte que no es
;; continuación 10xxxxxx, más sus continuaciones)
(func $texto_a_lista (param $t (ref $Texto)) (result (ref $Lista))
  (local $l (ref null $Lista))
  (local $n i32)
  (local $i i32)
  (local $ini i32)
  (local.set $n (array.len (local.get $t)))
  ;; los textos de 64 bytes o más pasan por la caché (los cortos son baratos
  ;; de reconvertir y no deben desalojar al fuente que trocea el lexer)
  (if (i32.ge_u (local.get $n) (i32.const 64))
    (then
      (if (call $c_acierta (global.get $ct0) (local.get $t))
        (then (return (ref.cast (ref $Lista) (global.get $cl0)))))
      (if (call $c_acierta (global.get $ct1) (local.get $t))
        (then (return (ref.cast (ref $Lista) (global.get $cl1)))))
      (if (call $c_acierta (global.get $ct2) (local.get $t))
        (then (return (ref.cast (ref $Lista) (global.get $cl2)))))
      (if (call $c_acierta (global.get $ct3) (local.get $t))
        (then (return (ref.cast (ref $Lista) (global.get $cl3)))))))
  (local.set $l (call $lista_nueva))
  (block $fin
    (loop $letras
      (br_if $fin (i32.ge_u (local.get $i) (local.get $n)))
      (local.set $ini (local.get $i))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (block $fin_letra
        (loop $continuaciones
          (br_if $fin_letra (i32.ge_u (local.get $i) (local.get $n)))
          (br_if $fin_letra (i32.ne (i32.and
            (array.get_u $Texto (local.get $t) (local.get $i)) (i32.const 192))
            (i32.const 128)))
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br $continuaciones)))
      (drop (call $lista_anade (ref.as_non_null (local.get $l))
        (call $texto_trozo (local.get $t) (local.get $ini)
              (i32.sub (local.get $i) (local.get $ini)))))
      (br $letras)))
  (if (i32.ge_u (local.get $n) (i32.const 64))
    (then
      (if (i32.eq (global.get $c_sig) (i32.const 0))
        (then (global.set $ct0 (local.get $t)) (global.set $cl0 (local.get $l))))
      (if (i32.eq (global.get $c_sig) (i32.const 1))
        (then (global.set $ct1 (local.get $t)) (global.set $cl1 (local.get $l))))
      (if (i32.eq (global.get $c_sig) (i32.const 2))
        (then (global.set $ct2 (local.get $t)) (global.set $cl2 (local.get $l))))
      (if (i32.eq (global.get $c_sig) (i32.const 3))
        (then (global.set $ct3 (local.get $t)) (global.set $cl3 (local.get $l))))
      (global.set $c_sig (i32.and (i32.add (global.get $c_sig) (i32.const 1))
                                  (i32.const 3)))))
  (ref.as_non_null (local.get $l)))

;; letra I de un texto: índice desde 1, con su error contado en letras
(func $texto_elemento (param $t (ref $Texto)) (param $indice anyref) (result anyref)
  (local $l (ref null $Lista))
  (local $i f64)
  (local $n i32)
  (local.set $l (call $texto_a_lista (local.get $t)))
  (local.set $n (struct.get $Lista $n (local.get $l)))
  (local.set $i (call $a_f64 (call $a_entero (local.get $indice))))
  ;; fuera del texto: "El texto tiene N letras y pediste la I."
  (if (i32.or (f64.lt (local.get $i) (f64.const 1))
              (f64.gt (local.get $i) (f64.convert_i32_s (local.get $n))))
    (then
      (call $panico (call $concatenar (call $concatenar (call $concatenar (call $concatenar
        (array.new_data $Texto $msg_indice_texto_pre (i32.const 0) (i32.const 22))
        (call $entero_a_texto (call $entero_de_i32 (local.get $n))))
        (array.new_data $Texto $msg_indice_texto_mid (i32.const 0) (i32.const 21)))
        (call $mostrar (call $a_entero (local.get $indice))))
        (array.new_data $Texto $msg_indice_texto_post (i32.const 0) (i32.const 1))))
      (unreachable)))
  (array.get $Items (struct.get $Lista $items (local.get $l))
             (i32.sub (i32.trunc_f64_s (local.get $i)) (i32.const 1))))

;; añade V a D: al final de una lista, o al final de un archivo (por su nombre)
(func $anade (param $v anyref) (param $d anyref)
  (if (ref.test (ref $Lista) (local.get $d))
    (then
      (drop (call $lista_anade (ref.cast (ref $Lista) (local.get $d)) (local.get $v)))
      (return)))
  (if (ref.test (ref $Texto) (local.get $d))
    (then
      (call $archivo_escribe (local.get $v) (ref.cast (ref $Texto) (local.get $d))
            (i32.const 1) (i32.const 1))  ;; crear sin machacar, y al final
      (return)))
  (call $panico (call $concatenar (call $concatenar
    (array.new_data $Texto $msg_anade_pre (i32.const 0) (i32.const 74))
    (call $mostrar (local.get $d)))
    (array.new_data $Texto $msg_anade_post (i32.const 0) (i32.const 1)))))

;; al azar entre A y B: uniforme y sin sesgo, por rechazo sobre el bignum
(func $al_azar (param $ax anyref) (param $bx anyref) (result anyref)
  (local $a (ref null $Entero))
  (local $b (ref null $Entero))
  (local $rango (ref null $Limbs))
  (local $n i32)
  (local $mascara i32)
  (local $cand (ref null $Limbs))
  (local $i i32)
  (local.set $a (call $a_entero (local.get $ax)))
  (local.set $b (call $a_entero (local.get $bx)))
  (if (i32.gt_s (call $num_compara (local.get $a) (local.get $b)) (i32.const 0))
    (then
      (call $panico (call $concatenar (call $concatenar (call $concatenar (call $concatenar
        (array.new_data $Texto $msg_azar_pre (i32.const 0) (i32.const 22))
        (call $entero_a_texto (ref.as_non_null (local.get $a))))
        (array.new_data $Texto $msg_azar_mid (i32.const 0) (i32.const 3)))
        (call $entero_a_texto (ref.as_non_null (local.get $b))))
        (array.new_data $Texto $msg_azar_post (i32.const 0) (i32.const 33))))
      (unreachable)))
  ;; rango = b - a + 1 (siempre positivo)
  (local.set $rango (struct.get $Entero $limbs (ref.cast (ref $Entero)
    (call $num_suma
      (call $num_resta (local.get $b) (local.get $a))
      (call $uno)))))
  (local.set $n (array.len (local.get $rango)))
  ;; máscara del limb alto: la menor 2^k - 1 que lo cubre (rechaza poco)
  (local.set $mascara (array.get $Limbs (local.get $rango) (i32.sub (local.get $n) (i32.const 1))))
  (local.set $mascara (i32.or (local.get $mascara) (i32.shr_u (local.get $mascara) (i32.const 1))))
  (local.set $mascara (i32.or (local.get $mascara) (i32.shr_u (local.get $mascara) (i32.const 2))))
  (local.set $mascara (i32.or (local.get $mascara) (i32.shr_u (local.get $mascara) (i32.const 4))))
  (local.set $mascara (i32.or (local.get $mascara) (i32.shr_u (local.get $mascara) (i32.const 8))))
  (local.set $mascara (i32.or (local.get $mascara) (i32.shr_u (local.get $mascara) (i32.const 16))))
  (block $aceptado
    (loop $prueba
      (drop (call $random_get (i32.const 16) (i32.mul (local.get $n) (i32.const 4))))
      (local.set $cand (array.new $Limbs (i32.const 0) (local.get $n)))
      (local.set $i (i32.const 0))
      (block $fin_copia
        (loop $copia
          (br_if $fin_copia (i32.ge_u (local.get $i) (local.get $n)))
          (array.set $Limbs (local.get $cand) (local.get $i)
                     (i32.load (i32.add (i32.const 16)
                                        (i32.mul (local.get $i) (i32.const 4)))))
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br $copia)))
      (array.set $Limbs (local.get $cand) (i32.sub (local.get $n) (i32.const 1))
                 (i32.and (array.get $Limbs (local.get $cand)
                            (i32.sub (local.get $n) (i32.const 1)))
                          (local.get $mascara)))
      (br_if $aceptado (i32.lt_s (call $limbs_compara
        (call $limbs_recorta (local.get $cand)) (local.get $rango)) (i32.const 0)))
      (br $prueba)))
  (call $num_suma (local.get $a)
    (struct.new $Entero (i32.const 0) (call $limbs_recorta (local.get $cand)))))

;; --- archivos, por la puerta WASI (el directorio preabierto es el fd 3) ---

;; exige un texto, con el error amable del intérprete
(func $exige_texto (param $x anyref) (result (ref $Texto))
  (if (ref.test (ref $Texto) (local.get $x))
    (then (return (ref.cast (ref $Texto) (local.get $x)))))
  (call $panico (call $concatenar (call $concatenar
    (array.new_data $Texto $msg_texto_pre (i32.const 0) (i32.const 41))
    (call $mostrar (local.get $x)))
    (array.new_data $Texto $msg_texto_post (i32.const 0) (i32.const 1))))
  (unreachable))

;; abre una ruta; devuelve el fd, o -1 si no se pudo
(func $abre (param $ruta (ref $Texto)) (param $oflags i32) (param $fdflags i32) (result i32)
  (local $largo i32)
  (local $i i32)
  (local.set $largo (array.len (local.get $ruta)))
  (block $fin_copia
    (loop $copia
      (br_if $fin_copia (i32.ge_u (local.get $i) (local.get $largo)))
      (i32.store8 (i32.add (i32.const 16) (local.get $i))
                  (array.get_u $Texto (local.get $ruta) (local.get $i)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $copia)))
  (if (i32.ne (call $path_open
        (i32.const 3)              ;; el directorio preabierto
        (i32.const 1)              ;; siguiendo enlaces simbólicos
        (i32.const 16) (local.get $largo)
        (local.get $oflags)
        (i64.const 2097254)        ;; derechos: leer, escribir, mover, tamaño
        (i64.const 2097254)
        (local.get $fdflags)
        (i32.const 8))             ;; el fd se deja en la dirección 8
        (i32.const 0))
    (then (return (i32.const -1))))
  (i32.load (i32.const 8)))

;; guarda V en "ruta" (machaca=1 trunca; alfinal=1 añade al final)
(func $archivo_escribe (param $v anyref) (param $ruta (ref $Texto))
                       (param $crea_solo i32) (param $alfinal i32)
  (local $fd i32)
  (local.set $fd (call $abre (local.get $ruta)
    ;; CREAT (1) y, si machaca, TRUNC (8)
    (i32.or (i32.const 1) (select (i32.const 0) (i32.const 8) (local.get $crea_solo)))
    (local.get $alfinal)))       ;; fdflags: APPEND es el bit 1
  (if (i32.lt_s (local.get $fd) (i32.const 0)) (then (unreachable)))
  (call $escribe_fd (local.get $fd) (call $mostrar (local.get $v)) (i32.const 0))
  (drop (call $fd_close (local.get $fd))))

(func $guarda (param $v anyref) (param $rutax anyref)
  (call $archivo_escribe (local.get $v) (call $exige_texto (local.get $rutax))
        (i32.const 0) (i32.const 0)))

;; los argumentos: la lista de textos que siguen al programa en la línea de
;; comandos (el argv[0], el nombre del programa, se descarta). Cada llamada
;; construye una lista NUEVA, como el intérprete.
(func $argumentos (result (ref $Lista))
  (local $argc i32)
  (local $tam_buf i32)
  (local $punteros i32)
  (local $buf i32)
  (local $i i32)
  (local $ptr i32)
  (local $fin i32)
  (local $largo i32)
  (local $j i32)
  (local $texto (ref null $Texto))
  (local $lista (ref $Lista))
  (drop (call $args_sizes_get (i32.const 8) (i32.const 12)))
  (local.set $argc (i32.load (i32.const 8)))
  (local.set $tam_buf (i32.load (i32.const 12)))
  (local.set $punteros (i32.const 16))
  (local.set $buf (i32.add (i32.const 16)
                           (i32.mul (local.get $argc) (i32.const 4))))
  ;; si no cabe en las páginas que hay, pide más
  (block $cabe
    (br_if $cabe (i32.lt_u (i32.add (local.get $buf)
                                    (i32.add (local.get $tam_buf) (i32.const 32)))
                           (i32.mul (memory.size) (i32.const 65536))))
    (drop (memory.grow (i32.add (i32.div_u (local.get $tam_buf) (i32.const 65536))
                                (i32.const 1)))))
  (drop (call $args_get (local.get $punteros) (local.get $buf)))
  (local.set $lista (call $lista_nueva))
  (local.set $i (i32.const 1))
  (block $fin_args
    (loop $args
      (br_if $fin_args (i32.ge_u (local.get $i) (local.get $argc)))
      (local.set $ptr (i32.load (i32.add (local.get $punteros)
                                         (i32.mul (local.get $i) (i32.const 4)))))
      ;; el final del texto: el puntero siguiente menos su NUL, o el final del buffer
      (if (i32.lt_u (i32.add (local.get $i) (i32.const 1)) (local.get $argc))
        (then (local.set $fin (i32.sub
          (i32.load (i32.add (local.get $punteros)
                             (i32.mul (i32.add (local.get $i) (i32.const 1)) (i32.const 4))))
          (i32.const 1))))
        (else (local.set $fin (i32.sub (i32.add (local.get $buf) (local.get $tam_buf))
                                       (i32.const 1)))))
      (local.set $largo (i32.sub (local.get $fin) (local.get $ptr)))
      (local.set $texto (array.new $Texto (i32.const 0) (local.get $largo)))
      (local.set $j (i32.const 0))
      (block $fin_copia
        (loop $copia
          (br_if $fin_copia (i32.ge_u (local.get $j) (local.get $largo)))
          (array.set $Texto (local.get $texto) (local.get $j)
                     (i32.load8_u (i32.add (local.get $ptr) (local.get $j))))
          (local.set $j (i32.add (local.get $j) (i32.const 1)))
          (br $copia)))
      (drop (call $lista_anade (local.get $lista)
                  (ref.as_non_null (local.get $texto))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $args)))
  (local.get $lista))

;; contenido de "ruta": el archivo entero como texto; si no está, error amable
(func $contenido (param $rutax anyref) (result anyref)
  (local $ruta (ref null $Texto))
  (local $fd i32)
  (local $acumulado (ref null $Texto))
  (local $trozo (ref null $Texto))
  (local $leidos i32)
  (local $i i32)
  (local.set $ruta (call $exige_texto (local.get $rutax)))
  (local.set $fd (call $abre (ref.as_non_null (local.get $ruta))
                       (i32.const 0) (i32.const 0)))
  (if (i32.lt_s (local.get $fd) (i32.const 0))
    (then
      (call $panico (call $concatenar (call $concatenar
        (array.new_data $Texto $msg_archivo_pre
                        (i32.const 0) (i32.const 32))
        (ref.as_non_null (local.get $ruta)))
        (array.new_data $Texto $msg_archivo_post
                        (i32.const 0) (i32.const 2))))
      (unreachable)))
  (local.set $acumulado (array.new $Texto (i32.const 0) (i32.const 0)))
  (block $fin_archivo
    (loop $lee
      (i32.store (i32.const 0) (i32.const 16))     ;; buffer del trozo
      (i32.store (i32.const 4) (i32.const 4096))
      (drop (call $fd_read (local.get $fd) (i32.const 0) (i32.const 1) (i32.const 8)))
      (local.set $leidos (i32.load (i32.const 8)))
      (br_if $fin_archivo (i32.eqz (local.get $leidos)))
      (local.set $trozo (array.new $Texto (i32.const 0) (local.get $leidos)))
      (local.set $i (i32.const 0))
      (block $fin_copia
        (loop $copia
          (br_if $fin_copia (i32.ge_u (local.get $i) (local.get $leidos)))
          (array.set $Texto (local.get $trozo) (local.get $i)
                     (i32.load8_u (i32.add (i32.const 16) (local.get $i))))
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br $copia)))
      (local.set $acumulado (call $concatenar
        (ref.as_non_null (local.get $acumulado))
        (ref.as_non_null (local.get $trozo))))
      (br $lee)))
  (drop (call $fd_close (local.get $fd)))
  (local.get $acumulado))

;; listas iguales: mismo largo y elementos iguales, uno a uno
(func $listas_iguales (param $a (ref $Lista)) (param $b (ref $Lista)) (result i32)
  (local $n i32)
  (local $i i32)
  (local.set $n (struct.get $Lista $n (local.get $a)))
  (if (i32.ne (local.get $n) (struct.get $Lista $n (local.get $b)))
    (then (return (i32.const 0))))
  (block $fin
    (loop $sigue
      (br_if $fin (i32.ge_u (local.get $i) (local.get $n)))
      (if (i32.eqz (call $iguales
            (array.get $Items (struct.get $Lista $items (local.get $a)) (local.get $i))
            (array.get $Items (struct.get $Lista $items (local.get $b)) (local.get $i))))
        (then (return (i32.const 0))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $sigue)))
  (i32.const 1))

;; una lista se enseña como [uno, dos, tres]
(func $lista_a_texto (param $l (ref $Lista)) (result (ref $Texto))
  (local $n i32)
  (local $i i32)
  (local $r (ref $Texto))
  (local.set $n (struct.get $Lista $n (local.get $l)))
  (local.set $r (array.new_fixed $Texto 1 (i32.const 91)))
  (block $fin
    (loop $sigue
      (br_if $fin (i32.ge_u (local.get $i) (local.get $n)))
      (if (i32.gt_u (local.get $i) (i32.const 0))
        (then (local.set $r (call $concatenar (local.get $r)
          (array.new_fixed $Texto 2 (i32.const 44) (i32.const 32))))))
      (local.set $r (call $concatenar (local.get $r) (call $mostrar
        (array.get $Items (struct.get $Lista $items (local.get $l)) (local.get $i)))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $sigue)))
  (call $concatenar (local.get $r) (array.new_fixed $Texto 1 (i32.const 93))))

;; --- tarjetas (registros con campos): construir, leer campo, mostrar, igualar ---

(func $tarjeta_nueva (param $tipo (ref $Texto)) (param $campos (ref $Items))
                        (param $valores (ref $Items)) (result (ref $Tarjeta))
  (struct.new $Tarjeta (local.get $tipo) (local.get $campos) (local.get $valores)))

;; $tarjeta_campo: el valor del campo llamado así; si no existe, para el programa.
;; $t llega como anyref (viene de una variable global/local) y se refina aquí.
(func $tarjeta_campo (param $t anyref) (param $campo (ref $Texto)) (result anyref)
  (local $tar (ref $Tarjeta))
  (local $n i32)
  (local $i i32)
  (local.set $tar (ref.cast (ref $Tarjeta) (local.get $t)))
  (local.set $n (array.len (struct.get $Tarjeta $campos (local.get $tar))))
  (block $fin
    (loop $sigue
      (br_if $fin (i32.ge_u (local.get $i) (local.get $n)))
      (if (call $textos_iguales
            (ref.cast (ref $Texto)
              (array.get $Items (struct.get $Tarjeta $campos (local.get $tar)) (local.get $i)))
            (local.get $campo))
        (then
          (return (array.get $Items (struct.get $Tarjeta $valores (local.get $tar))
                             (local.get $i)))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $sigue)))
  (call $panico (call $concatenar
    (call $concatenar (array.new_data $Texto $msg_campo_pre (i32.const 0) (i32.const 50))
                       (local.get $campo))
    (array.new_data $Texto $msg_campo_post (i32.const 0) (i32.const 1))))
  (unreachable))

(func $tarjeta_a_texto (param $t (ref $Tarjeta)) (result (ref $Texto))
  (local $n i32)
  (local $i i32)
  (local $r (ref $Texto))
  (local.set $n (array.len (struct.get $Tarjeta $campos (local.get $t))))
  ;; "tipo{"
  (local.set $r (call $concatenar (struct.get $Tarjeta $tipo (local.get $t))
                          (array.new_fixed $Texto 1 (i32.const 123))))
  (block $fin
    (loop $sigue
      (br_if $fin (i32.ge_u (local.get $i) (local.get $n)))
      (if (i32.gt_u (local.get $i) (i32.const 0))
        (then (local.set $r (call $concatenar (local.get $r)
          (array.new_fixed $Texto 2 (i32.const 44) (i32.const 32))))))   ;; ", "
      ;; campo
      (local.set $r (call $concatenar (local.get $r)
        (ref.cast (ref $Texto)
          (array.get $Items (struct.get $Tarjeta $campos (local.get $t)) (local.get $i)))))
      ;; ": "
      (local.set $r (call $concatenar (local.get $r)
        (array.new_fixed $Texto 2 (i32.const 58) (i32.const 32))))
      ;; valor
      (local.set $r (call $concatenar (local.get $r)
        (call $mostrar (array.get $Items (struct.get $Tarjeta $valores (local.get $t))
                                   (local.get $i)))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $sigue)))
  (call $concatenar (local.get $r) (array.new_fixed $Texto 1 (i32.const 125))))  ;; "}"

(func $tarjetas_iguales (param $a (ref $Tarjeta)) (param $b (ref $Tarjeta)) (result i32)
  (local $n i32)
  (local $i i32)
  (if (i32.eqz (call $textos_iguales (struct.get $Tarjeta $tipo (local.get $a))
                                     (struct.get $Tarjeta $tipo (local.get $b))))
    (then (return (i32.const 0))))
  (local.set $n (array.len (struct.get $Tarjeta $campos (local.get $a))))
  (if (i32.ne (local.get $n) (array.len (struct.get $Tarjeta $campos (local.get $b))))
    (then (return (i32.const 0))))
  (block $fin
    (loop $sigue
      (br_if $fin (i32.ge_u (local.get $i) (local.get $n)))
      (if (i32.eqz (call $textos_iguales
            (ref.cast (ref $Texto)
              (array.get $Items (struct.get $Tarjeta $campos (local.get $a)) (local.get $i)))
            (ref.cast (ref $Texto)
              (array.get $Items (struct.get $Tarjeta $campos (local.get $b)) (local.get $i)))))
        (then (return (i32.const 0))))
      (if (i32.eqz (call $iguales
            (array.get $Items (struct.get $Tarjeta $valores (local.get $a)) (local.get $i))
            (array.get $Items (struct.get $Tarjeta $valores (local.get $b)) (local.get $i))))
        (then (return (i32.const 0))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $sigue)))
  (i32.const 1))
