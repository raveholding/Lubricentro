-- =====================================================================
-- LUBRICENTRO SALTA · Stock y trazabilidad por lotes
-- Esquema relacional (PostgreSQL). La demo HTML usa el mismo modelo en memoria.
-- Principio: el stock NO se guarda; se obtiene sumando el libro de movimientos.
-- Desarrollado por VINCULAR BUSINESS · (387) 4484132 · vincularbusiness@gmail.com
-- =====================================================================

CREATE TABLE configuracion (
  clave  text PRIMARY KEY,
  valor  text NOT NULL
);
INSERT INTO configuracion VALUES ('criterio_salida','FEFO'), ('dias_alerta_vencimiento','60');

CREATE TABLE categorias (
  id      serial PRIMARY KEY,
  nombre  text NOT NULL UNIQUE
);

CREATE TABLE unidades_medida (
  id      serial PRIMARY KEY,
  codigo  text NOT NULL UNIQUE          -- Un, Lt, Kg, Bidón, Pack
);

CREATE TABLE productos (
  id               serial PRIMARY KEY,
  codigo           text    NOT NULL UNIQUE,         -- código de barras / QR
  nombre           text    NOT NULL,
  marca            text,
  categoria_id     int     NOT NULL REFERENCES categorias(id),
  unidad_id        int     NOT NULL REFERENCES unidades_medida(id),
  stock_minimo     numeric(12,3) NOT NULL DEFAULT 0 CHECK (stock_minimo >= 0),
  punto_reorden    numeric(12,3) NOT NULL DEFAULT 0,
  precio_venta     numeric(12,2) NOT NULL DEFAULT 0,
  costo_referencia numeric(12,2) NOT NULL DEFAULT 0,
  controla_venc    boolean NOT NULL DEFAULT true,   -- exige vencimiento en cada lote
  activo           boolean NOT NULL DEFAULT true,   -- baja lógica (conserva historial)
  CHECK (punto_reorden >= stock_minimo)
);

CREATE TABLE proveedores (
  id         serial PRIMARY KEY,
  razon      text NOT NULL,
  cuit       text,
  contacto   text,
  telefono   text,
  email      text,
  direccion  text,
  notas      text,
  activo     boolean NOT NULL DEFAULT true
);

-- Cabecera del remito / factura de compra
CREATE TABLE compras (
  id            serial PRIMARY KEY,
  proveedor_id  int  NOT NULL REFERENCES proveedores(id),
  tipo          text NOT NULL CHECK (tipo IN ('Remito','Factura A','Factura B','Factura C','Factura X')),
  numero        text NOT NULL,
  fecha         date NOT NULL DEFAULT current_date,
  total         numeric(14,2) NOT NULL DEFAULT 0,
  observaciones text,
  UNIQUE (proveedor_id, tipo, numero)               -- evita cargar dos veces el mismo comprobante
);

-- Un lote = un producto + un número de lote + un vencimiento, nacido de una compra
CREATE TABLE lotes (
  id            serial PRIMARY KEY,
  producto_id   int  NOT NULL REFERENCES productos(id),
  nro_lote      text NOT NULL,
  vencimiento   date,                               -- NULL = producto sin vencimiento
  fecha_ingreso date NOT NULL,
  compra_id     int  NOT NULL REFERENCES compras(id),
  proveedor_id  int  NOT NULL REFERENCES proveedores(id),
  cant_inicial  numeric(12,3) NOT NULL CHECK (cant_inicial > 0),
  costo_unit    numeric(12,2) NOT NULL CHECK (costo_unit >= 0),
  UNIQUE (producto_id, nro_lote)
);
CREATE INDEX idx_lotes_fefo ON lotes (producto_id, vencimiento NULLS LAST, fecha_ingreso, id);

CREATE TABLE compra_items (
  id          serial PRIMARY KEY,
  compra_id   int NOT NULL REFERENCES compras(id) ON DELETE CASCADE,
  producto_id int NOT NULL REFERENCES productos(id),
  lote_id     int NOT NULL REFERENCES lotes(id),    -- renglón vinculado a su lote
  cantidad    numeric(12,3) NOT NULL CHECK (cantidad > 0),
  costo_unit  numeric(12,2) NOT NULL CHECK (costo_unit >= 0)
);

CREATE TABLE ventas (
  id       serial PRIMARY KEY,
  fecha    timestamp NOT NULL DEFAULT now(),
  cliente  text NOT NULL DEFAULT 'Consumidor final',
  medio_pago text NOT NULL DEFAULT 'Efectivo',
  total    numeric(14,2) NOT NULL DEFAULT 0
);

CREATE TABLE venta_items (
  id          serial PRIMARY KEY,
  venta_id    int NOT NULL REFERENCES ventas(id) ON DELETE CASCADE,
  producto_id int NOT NULL REFERENCES productos(id),
  cantidad    numeric(12,3) NOT NULL CHECK (cantidad > 0),
  precio_unit numeric(12,2) NOT NULL
);

-- LIBRO DE MOVIMIENTOS: única fuente de verdad del stock (cantidad con signo)
CREATE TYPE tipo_movimiento AS ENUM ('ENTRADA','VENTA','MERMA','VENCIDO','ROTURA','AJUSTE_POS','AJUSTE_NEG');

CREATE TABLE movimientos_stock (
  id           bigserial PRIMARY KEY,
  fecha        timestamp NOT NULL DEFAULT now(),
  tipo         tipo_movimiento NOT NULL,
  lote_id      int NOT NULL REFERENCES lotes(id),
  producto_id  int NOT NULL REFERENCES productos(id),
  cantidad     numeric(12,3) NOT NULL CHECK (cantidad <> 0),   -- + entra, − sale
  costo_unit   numeric(12,2) NOT NULL DEFAULT 0,
  ref_tipo     text,                                           -- 'compra' | 'venta' | 'ajuste'
  ref_id       int,
  motivo       text,
  CHECK ((tipo IN ('ENTRADA','AJUSTE_POS') AND cantidad > 0) OR (tipo NOT IN ('ENTRADA','AJUSTE_POS') AND cantidad < 0)),
  CHECK (tipo NOT IN ('MERMA','VENCIDO','ROTURA','AJUSTE_NEG','AJUSTE_POS') OR motivo IS NOT NULL)  -- ajustes exigen motivo
);
CREATE INDEX idx_mov_lote ON movimientos_stock (lote_id, fecha);

-- Detalle de qué lotes componen cada renglón de venta (trazabilidad hacia adelante)
CREATE TABLE venta_item_lotes (
  id            serial PRIMARY KEY,
  venta_item_id int NOT NULL REFERENCES venta_items(id) ON DELETE CASCADE,
  lote_id       int NOT NULL REFERENCES lotes(id),
  movimiento_id bigint NOT NULL REFERENCES movimientos_stock(id),
  cantidad      numeric(12,3) NOT NULL CHECK (cantidad > 0),
  costo_unit    numeric(12,2) NOT NULL
);

-- Los movimientos no se editan ni se borran: sólo se compensan con otro movimiento
CREATE FUNCTION trg_mov_inmutable() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'movimientos_stock es de sólo agregar; corregí con un ajuste'; END $$;
CREATE TRIGGER mov_inmutable BEFORE UPDATE OR DELETE ON movimientos_stock
  FOR EACH ROW EXECUTE FUNCTION trg_mov_inmutable();

-- Un lote nunca puede quedar con stock negativo
CREATE FUNCTION trg_mov_sin_negativos() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE saldo numeric;
BEGIN
  SELECT COALESCE(SUM(cantidad),0) + NEW.cantidad INTO saldo FROM movimientos_stock WHERE lote_id = NEW.lote_id;
  IF saldo < 0 THEN RAISE EXCEPTION 'El lote % quedaría con stock negativo (%)', NEW.lote_id, saldo; END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER mov_sin_negativos BEFORE INSERT ON movimientos_stock
  FOR EACH ROW EXECUTE FUNCTION trg_mov_sin_negativos();

-- =====================================================================
-- VISTAS (stock, alertas, valorización)
-- =====================================================================
CREATE VIEW v_stock_lote AS
SELECT l.id AS lote_id, l.producto_id, l.nro_lote, l.vencimiento, l.fecha_ingreso, l.costo_unit,
       COALESCE(SUM(m.cantidad),0) AS stock,
       COALESCE(SUM(m.cantidad),0) * l.costo_unit AS valor,
       CASE WHEN l.vencimiento IS NULL THEN 'sin'
            WHEN l.vencimiento < current_date THEN 'vencido'
            WHEN l.vencimiento <= current_date + (SELECT valor::int FROM configuracion WHERE clave='dias_alerta_vencimiento') THEN 'proximo'
            ELSE 'ok' END AS estado_venc
FROM lotes l LEFT JOIN movimientos_stock m ON m.lote_id = l.id
GROUP BY l.id;

-- Stock disponible = lotes no vencidos
CREATE VIEW v_stock_producto AS
SELECT p.id AS producto_id, p.nombre, p.stock_minimo, p.punto_reorden,
       COALESCE(SUM(s.stock) FILTER (WHERE s.estado_venc <> 'vencido'),0) AS disponible,
       COALESCE(SUM(s.stock) FILTER (WHERE s.estado_venc = 'vencido'),0)  AS vencido
FROM productos p LEFT JOIN v_stock_lote s ON s.producto_id = p.id
WHERE p.activo GROUP BY p.id;

CREATE VIEW v_alertas_stock AS
SELECT *, CASE WHEN disponible <= stock_minimo THEN 'CRITICO' ELSE 'REORDEN' END AS nivel
FROM v_stock_producto WHERE disponible <= punto_reorden;

CREATE VIEW v_alertas_vencimiento AS
SELECT s.*, p.nombre, (s.vencimiento - current_date) AS dias
FROM v_stock_lote s JOIN productos p ON p.id = s.producto_id
WHERE s.stock > 0 AND s.estado_venc IN ('proximo','vencido');

CREATE VIEW v_valorizacion AS
SELECT c.nombre AS categoria, p.nombre AS producto, s.nro_lote, s.stock, s.costo_unit, s.valor
FROM v_stock_lote s JOIN productos p ON p.id = s.producto_id JOIN categorias c ON c.id = p.categoria_id
WHERE s.stock > 0;

-- =====================================================================
-- FLUJO DE VENTA: elegir lotes por FEFO (o FIFO) y descontar
-- Devuelve los lotes y cantidades sugeridas; la aplicación inserta los movimientos VENTA.
-- Los lotes vencidos nunca se asignan.
-- =====================================================================
CREATE FUNCTION fn_sugerir_lotes(p_producto int, p_cantidad numeric, p_criterio text DEFAULT 'FEFO')
RETURNS TABLE (lote_id int, cantidad numeric) LANGUAGE plpgsql AS $$
DECLARE rest numeric := p_cantidad; r record;
BEGIN
  FOR r IN
    SELECT s.lote_id, s.stock FROM v_stock_lote s
    WHERE s.producto_id = p_producto AND s.stock > 0 AND s.estado_venc <> 'vencido'
    ORDER BY CASE WHEN p_criterio = 'FEFO' THEN s.vencimiento END NULLS LAST, s.fecha_ingreso, s.lote_id
  LOOP
    EXIT WHEN rest <= 0;
    lote_id := r.lote_id; cantidad := LEAST(rest, r.stock); rest := rest - cantidad; RETURN NEXT;
  END LOOP;
  IF rest > 0 THEN RAISE EXCEPTION 'Stock insuficiente: faltan % unidades', rest; END IF;
END $$;

-- Trazabilidad de un lote: origen + cadena de movimientos con saldo corrido
CREATE VIEW v_trazabilidad_lote AS
SELECT m.lote_id, l.nro_lote, p.nombre AS producto, pr.razon AS proveedor,
       c.tipo || ' ' || c.numero AS comprobante_origen,
       m.fecha, m.tipo, m.cantidad, m.ref_tipo, m.ref_id, m.motivo,
       SUM(m.cantidad) OVER (PARTITION BY m.lote_id ORDER BY m.fecha, m.id) AS saldo
FROM movimientos_stock m
JOIN lotes l ON l.id = m.lote_id JOIN productos p ON p.id = l.producto_id
JOIN proveedores pr ON pr.id = l.proveedor_id JOIN compras c ON c.id = l.compra_id;
