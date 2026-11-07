"""
AutoAudit - Interfaz de configuracion y reportes.

La interfaz no construye SQL de configuracion por su cuenta. Llama a las
funciones del esquema audit, donde viven la validacion contra el diccionario
de datos y la restriccion de privilegios administrativos. De ese modo una
configuracion hecha desde psql pasa por los mismos controles que una hecha
desde aqui, y el cliente no es el que decide quien puede configurar.

Requisitos:
    sudo dnf install -y python3-tkinter     # en Fedora tkinter va aparte
    pip install psycopg2-binary

Conexion, tomada del entorno para no dejar credenciales en el codigo:
    export AUTOAUDIT_DB=autoaudit
    export AUTOAUDIT_USER=$USER
    export PGPASSWORD=...                   # solo si el servidor la pide
    python3 autoaudit_app.py
"""

import os
import csv
import getpass
from datetime import datetime

import tkinter as tk
from tkinter import ttk, messagebox, filedialog

import psycopg2


def configuracion_conexion():
    cfg = {
        "dbname": os.environ.get("AUTOAUDIT_DB", "autoaudit"),
        "user":   os.environ.get("AUTOAUDIT_USER", getpass.getuser()),
        "host":   os.environ.get("AUTOAUDIT_HOST", "localhost"),
        "port":   os.environ.get("AUTOAUDIT_PORT", "5432"),
    }
    clave = os.environ.get("PGPASSWORD")
    if clave:
        cfg["password"] = clave
    return cfg


def parsear_fecha(texto, fin_del_dia=False):
    """Convierte 'AAAA-MM-DD' en datetime. Devuelve None si el campo esta vacio."""
    texto = (texto or "").strip()
    if not texto:
        return None
    try:
        f = datetime.strptime(texto, "%Y-%m-%d")
    except ValueError:
        raise ValueError(f"Fecha invalida: {texto}. Use el formato AAAA-MM-DD.")
    return f.replace(hour=23, minute=59, second=59) if fin_del_dia else f


# =============================================================================
# Capa de datos. Sin dependencia de tkinter, de modo que puede probarse sola.
# =============================================================================
class AutoAuditDB:

    def __init__(self, cfg):
        self.conn = psycopg2.connect(**cfg)
        self.conn.autocommit = False

    def cerrar(self):
        self.conn.close()

    def _leer(self, sql, params=None):
        """
        Ejecuta una consulta de lectura y cierra la transaccion siempre.

        El rollback del bloque except es indispensable: sin el, una consulta
        fallida deja la transaccion abortada y todo lo que venga despues falla
        con 'current transaction is aborted' hasta reiniciar la aplicacion.
        """
        try:
            with self.conn.cursor() as cur:
                cur.execute(sql, params)
                filas = cur.fetchall()
            self.conn.rollback()
            return filas
        except Exception:
            self.conn.rollback()
            raise

    def _ejecutar(self, sql, params=None):
        """Llama a una funcion que modifica estado y confirma la transaccion."""
        try:
            with self.conn.cursor() as cur:
                cur.execute(sql, params)
                fila = cur.fetchone()
            self.conn.commit()
            return fila[0] if fila else None
        except Exception:
            self.conn.rollback()
            raise

    # -- diccionario de datos -------------------------------------------------

    def es_administrador(self):
        return self._leer("SELECT audit.fn_es_administrador();")[0][0]

    def tablas_auditables(self):
        filas = self._leer("""
            SELECT esquema, tabla FROM audit.v_diccionario_tablas
             WHERE tiene_llave_primaria ORDER BY esquema, tabla;
        """)
        return [f"{e}.{t}" for e, t in filas]

    def columnas_de(self, esquema, tabla):
        return self._leer("""
            SELECT columna, tipo_dato, es_llave_primaria
              FROM audit.v_diccionario_columnas
             WHERE esquema = %s AND tabla = %s ORDER BY posicion;
        """, (esquema, tabla))

    def estado_auditoria(self):
        return self._leer("""
            SELECT esquema || '.' || tabla, tabla_activa, trigger_desplegado,
                   columnas_activas, eventos_insert, eventos_update, eventos_delete
              FROM audit.v_estado_auditoria ORDER BY esquema, tabla;
        """)

    def columnas_configuradas_de(self, esquema, tabla):
        filas = self._leer("""
            SELECT col.columna, col.activa
              FROM audit.columna_auditada col
              JOIN audit.tabla_auditada ta ON ta.id = col.tabla_auditada_id
             WHERE ta.esquema = %s AND ta.tabla = %s
             ORDER BY col.columna;
        """, (esquema, tabla))
        return filas

    # -- configuracion --------------------------------------------------------

    def configurar(self, esquema, tabla, columnas, eventos):
        return self._ejecutar(
            "SELECT audit.configurar_auditoria(%s, %s, %s, %s);",
            (esquema, tabla, list(columnas), list(eventos)))

    def desactivar_evento(self, esquema, tabla, columna, evento):
        return self._ejecutar(
            "SELECT audit.desactivar_evento(%s, %s, %s, %s);",
            (esquema, tabla, columna, evento))

    def activar_evento(self, esquema, tabla, columna, evento):
        return self._ejecutar(
            "SELECT audit.activar_evento(%s, %s, %s, %s);",
            (esquema, tabla, columna, evento))

    def desactivar_columna(self, esquema, tabla, columna):
        return self._ejecutar(
            "SELECT audit.desactivar_columna(%s, %s, %s);", (esquema, tabla, columna))

    def desactivar_tabla(self, esquema, tabla):
        return self._ejecutar("SELECT audit.desactivar_tabla(%s, %s);", (esquema, tabla))

    def activar_tabla(self, esquema, tabla):
        return self._ejecutar("SELECT audit.activar_tabla(%s, %s);", (esquema, tabla))

    # -- reportes -------------------------------------------------------------

    def usuarios(self):
        return self._leer(
            "SELECT id, nombre_usuario FROM audit.usuario_auditado ORDER BY nombre_usuario;")

    def columnas_para_filtro(self):
        return self._leer("""
            SELECT col.id, ta.esquema || '.' || ta.tabla || '.' || col.columna
              FROM audit.columna_auditada col
              JOIN audit.tabla_auditada ta ON ta.id = col.tabla_auditada_id
             ORDER BY 2;
        """)

    def historial(self, usuario_id=None, columna_id=None, desde=None, hasta=None, limite=1000):
        return self._leer("""
            SELECT fecha_hora, nombre_usuario, direccion_ip, objeto, columna,
                   evento, clave_primaria, valor_anterior, valor_nuevo
              FROM audit.consultar_historial(
                   p_usuario_id          => %s,
                   p_columna_auditada_id => %s,
                   p_desde               => %s,
                   p_hasta               => %s,
                   p_limite              => %s);
        """, (usuario_id, columna_id, desde, hasta, limite))


# =============================================================================
# Interfaz
# =============================================================================
class AutoAuditApp:

    COLUMNAS_REPORTE = ("fecha_hora", "usuario", "ip", "objeto", "columna",
                        "evento", "clave_primaria", "valor_anterior", "valor_nuevo")
    EVENTOS = ("INSERT", "UPDATE", "DELETE")

    def __init__(self, root, db):
        self.root = root
        self.db = db
        root.title("AutoAudit - Configuracion y reportes")
        root.geometry("1060x680")

        self.mapa_usuarios = {}
        self.mapa_columnas = {}

        self.notebook = ttk.Notebook(root)
        self.notebook.pack(fill="both", expand=True, padx=8, pady=8)

        self._tab_configuracion()
        self._tab_bitacora()
        self._tab_estado()

        if not self._es_admin():
            messagebox.showwarning(
                "Sin privilegios administrativos",
                "La sesion actual puede consultar la bitacora pero no configurar\n"
                "auditoria. La base rechazara los intentos de configuracion.")

    def _es_admin(self):
        try:
            return self.db.es_administrador()
        except Exception:
            return False

    # -- pestana de configuracion --------------------------------------------

    def _tab_configuracion(self):
        tab = ttk.Frame(self.notebook, padding=14)
        self.notebook.add(tab, text="Configuracion")

        alta = ttk.LabelFrame(tab, text="Activar auditoria", padding=12)
        alta.pack(fill="x")

        ttk.Label(alta, text="Tabla").grid(row=0, column=0, sticky="w", pady=4)
        self.combo_tablas = ttk.Combobox(alta, state="readonly", width=44)
        self.combo_tablas.grid(row=0, column=1, sticky="w", pady=4)
        self.combo_tablas.bind("<<ComboboxSelected>>", self._al_elegir_tabla)

        ttk.Label(alta, text="Columnas").grid(row=1, column=0, sticky="nw", pady=4)
        marco_lista = ttk.Frame(alta)
        marco_lista.grid(row=1, column=1, sticky="w", pady=4)
        self.lista_columnas = tk.Listbox(marco_lista, selectmode="extended",
                                         height=7, width=42, exportselection=False)
        barra = ttk.Scrollbar(marco_lista, orient="vertical",
                              command=self.lista_columnas.yview)
        self.lista_columnas.configure(yscrollcommand=barra.set)
        self.lista_columnas.pack(side="left")
        barra.pack(side="left", fill="y")
        ttk.Label(alta, text="Ctrl o Shift para elegir varias",
                  foreground="#666").grid(row=2, column=1, sticky="w")

        ttk.Label(alta, text="Eventos").grid(row=3, column=0, sticky="w", pady=(10, 4))
        marco_ev = ttk.Frame(alta)
        marco_ev.grid(row=3, column=1, sticky="w", pady=(10, 4))
        self.vars_evento = {}
        for ev in self.EVENTOS:
            v = tk.BooleanVar(value=True)
            self.vars_evento[ev] = v
            ttk.Checkbutton(marco_ev, text=ev, variable=v).pack(side="left", padx=(0, 14))

        ttk.Button(alta, text="Activar auditoria",
                   command=self.activar_auditoria).grid(row=4, column=1, sticky="w", pady=12)

        baja = ttk.LabelFrame(tab, text="Suspender auditoria", padding=12)
        baja.pack(fill="x", pady=(14, 0))

        ttk.Label(baja, text="Columna configurada").grid(row=0, column=0, sticky="w", pady=4)
        self.combo_col_baja = ttk.Combobox(baja, state="readonly", width=30)
        self.combo_col_baja.grid(row=0, column=1, sticky="w", pady=4, padx=(0, 10))

        ttk.Label(baja, text="Evento").grid(row=0, column=2, sticky="w", pady=4)
        self.combo_ev_baja = ttk.Combobox(baja, state="readonly", width=12,
                                          values=self.EVENTOS)
        self.combo_ev_baja.current(1)
        self.combo_ev_baja.grid(row=0, column=3, sticky="w", pady=4, padx=(0, 10))

        acciones = ttk.Frame(baja)
        acciones.grid(row=1, column=0, columnspan=4, sticky="w", pady=(10, 0))
        ttk.Button(acciones, text="Desactivar evento",
                   command=self.desactivar_evento).pack(side="left", padx=(0, 8))
        ttk.Button(acciones, text="Reactivar evento",
                   command=self.activar_evento).pack(side="left", padx=(0, 8))
        ttk.Button(acciones, text="Desactivar columna",
                   command=self.desactivar_columna).pack(side="left", padx=(0, 8))
        ttk.Button(acciones, text="Suspender tabla completa",
                   command=self.desactivar_tabla).pack(side="left")

        nota = ("Solo se listan tablas con llave primaria: sin ella la bitacora no podria\n"
                "identificar el registro afectado y el generador las rechaza.\n\n"
                "Desactivar un evento surte efecto de inmediato. Desactivar una columna o una\n"
                "tabla obliga a regenerar el trigger, cosa que estas acciones ya hacen solas.")
        ttk.Label(tab, text=nota, foreground="#555",
                  justify="left").pack(anchor="w", pady=(14, 0))

        self.cargar_tablas()

    def cargar_tablas(self):
        try:
            self.combo_tablas["values"] = self.db.tablas_auditables()
        except Exception as e:
            messagebox.showerror("Error al leer el diccionario de datos", str(e))

    def _tabla_elegida(self):
        sel = self.combo_tablas.get()
        if not sel:
            return None, None
        esquema, tabla = sel.split(".", 1)
        return esquema, tabla

    def _al_elegir_tabla(self, _evento=None):
        esquema, tabla = self._tabla_elegida()
        if not esquema:
            return
        try:
            columnas = self.db.columnas_de(esquema, tabla)
            configuradas = self.db.columnas_configuradas_de(esquema, tabla)
        except Exception as e:
            messagebox.showerror("Error al leer columnas", str(e))
            return

        self.lista_columnas.delete(0, tk.END)
        self.nombres_columnas = []
        for nombre, tipo, es_pk in columnas:
            self.nombres_columnas.append(nombre)
            etiqueta = f"{nombre}  ({tipo})" + ("  [PK]" if es_pk else "")
            self.lista_columnas.insert(tk.END, etiqueta)

        self.combo_col_baja["values"] = [c for c, _ in configuradas]
        self.combo_col_baja.set("")

    def _columnas_seleccionadas(self):
        return [self.nombres_columnas[i] for i in self.lista_columnas.curselection()]

    def _eventos_seleccionados(self):
        return [ev for ev, v in self.vars_evento.items() if v.get()]

    def _reportar(self, accion, *args):
        """Ejecuta una accion de configuracion y traduce el error del motor."""
        try:
            mensaje = accion(*args)
        except psycopg2.errors.InsufficientPrivilege as e:
            messagebox.showerror("Sin privilegios", str(e).strip())
            return False
        except psycopg2.Error as e:
            messagebox.showerror("La base rechazo la operacion", str(e).strip())
            return False
        except Exception as e:
            messagebox.showerror("Error", str(e))
            return False

        messagebox.showinfo("Listo", mensaje)
        self._al_elegir_tabla()
        self.refrescar_estado()
        self.cargar_filtros()
        return True

    def activar_auditoria(self):
        esquema, tabla = self._tabla_elegida()
        if not esquema:
            messagebox.showwarning("Faltan datos", "Elija una tabla.")
            return
        columnas = self._columnas_seleccionadas()
        if not columnas:
            messagebox.showwarning("Faltan datos", "Elija al menos una columna.")
            return
        eventos = self._eventos_seleccionados()
        if not eventos:
            messagebox.showwarning("Faltan datos", "Elija al menos un evento.")
            return
        self._reportar(self.db.configurar, esquema, tabla, columnas, eventos)

    def _columna_baja(self):
        esquema, tabla = self._tabla_elegida()
        columna = self.combo_col_baja.get()
        if not esquema or not columna:
            messagebox.showwarning("Faltan datos", "Elija una tabla y una columna configurada.")
            return None, None, None
        return esquema, tabla, columna

    def desactivar_evento(self):
        esquema, tabla, columna = self._columna_baja()
        if not esquema:
            return
        self._reportar(self.db.desactivar_evento, esquema, tabla, columna,
                       self.combo_ev_baja.get())

    def activar_evento(self):
        esquema, tabla, columna = self._columna_baja()
        if not esquema:
            return
        self._reportar(self.db.activar_evento, esquema, tabla, columna,
                       self.combo_ev_baja.get())

    def desactivar_columna(self):
        esquema, tabla, columna = self._columna_baja()
        if not esquema:
            return
        if not messagebox.askyesno(
                "Confirmar",
                f"Dejar de vigilar {esquema}.{tabla}.{columna}?\n\n"
                "El trigger se regenera sin esa columna. La bitacora ya acumulada se conserva."):
            return
        self._reportar(self.db.desactivar_columna, esquema, tabla, columna)

    def desactivar_tabla(self):
        esquema, tabla = self._tabla_elegida()
        if not esquema:
            messagebox.showwarning("Faltan datos", "Elija una tabla.")
            return
        if not messagebox.askyesno(
                "Confirmar",
                f"Suspender la auditoria de {esquema}.{tabla}?\n\n"
                "Se retira el trigger. La configuracion y la bitacora se conservan\n"
                "y puede reanudarse desde la pestana Estado."):
            return
        self._reportar(self.db.desactivar_tabla, esquema, tabla)

    # -- pestana de bitacora --------------------------------------------------

    def _tab_bitacora(self):
        tab = ttk.Frame(self.notebook, padding=10)
        self.notebook.add(tab, text="Bitacora")

        filtros = ttk.Frame(tab)
        filtros.pack(fill="x", pady=(0, 10))

        ttk.Label(filtros, text="Usuario").grid(row=0, column=0, sticky="w", padx=(0, 5))
        self.combo_usuario = ttk.Combobox(filtros, state="readonly", width=18)
        self.combo_usuario.grid(row=0, column=1, padx=(0, 12))

        ttk.Label(filtros, text="Columna").grid(row=0, column=2, sticky="w", padx=(0, 5))
        self.combo_columna_filtro = ttk.Combobox(filtros, state="readonly", width=30)
        self.combo_columna_filtro.grid(row=0, column=3, padx=(0, 12))

        ttk.Label(filtros, text="Desde").grid(row=1, column=0, sticky="w", padx=(0, 5), pady=(8, 0))
        self.entry_desde = ttk.Entry(filtros, width=14)
        self.entry_desde.grid(row=1, column=1, sticky="w", pady=(8, 0))

        ttk.Label(filtros, text="Hasta").grid(row=1, column=2, sticky="w", padx=(0, 5), pady=(8, 0))
        self.entry_hasta = ttk.Entry(filtros, width=14)
        self.entry_hasta.grid(row=1, column=3, sticky="w", pady=(8, 0))

        ttk.Label(filtros, text="AAAA-MM-DD", foreground="#777").grid(
            row=1, column=4, sticky="w", padx=(6, 0), pady=(8, 0))

        botones = ttk.Frame(filtros)
        botones.grid(row=0, column=5, rowspan=2, padx=(18, 0))
        ttk.Button(botones, text="Buscar", command=self.generar_reporte).pack(side="left", padx=3)
        ttk.Button(botones, text="Limpiar", command=self.limpiar_filtros).pack(side="left", padx=3)
        ttk.Button(botones, text="Exportar CSV", command=self.exportar_csv).pack(side="left", padx=3)

        contenedor = ttk.Frame(tab)
        contenedor.pack(fill="both", expand=True)

        self.tree = ttk.Treeview(contenedor, columns=self.COLUMNAS_REPORTE, show="headings")
        anchos = {"fecha_hora": 155, "usuario": 85, "ip": 95, "objeto": 115,
                  "columna": 85, "evento": 65, "clave_primaria": 105,
                  "valor_anterior": 115, "valor_nuevo": 115}
        for col in self.COLUMNAS_REPORTE:
            self.tree.heading(col, text=col)
            self.tree.column(col, width=anchos.get(col, 100), anchor="w")
        barra = ttk.Scrollbar(contenedor, orient="vertical", command=self.tree.yview)
        self.tree.configure(yscrollcommand=barra.set)
        self.tree.pack(side="left", fill="both", expand=True)
        barra.pack(side="right", fill="y")

        self.etiqueta_conteo = ttk.Label(tab, text="", foreground="#555")
        self.etiqueta_conteo.pack(anchor="w", pady=(6, 0))

        self.cargar_filtros()
        self.generar_reporte()

    def cargar_filtros(self):
        try:
            usuarios = self.db.usuarios()
            columnas = self.db.columnas_para_filtro()
        except Exception as e:
            messagebox.showerror("Error al cargar filtros", str(e))
            return
        self.mapa_usuarios = {n: i for i, n in usuarios}
        self.mapa_columnas = {e: i for i, e in columnas}
        self.combo_usuario["values"] = [""] + list(self.mapa_usuarios)
        self.combo_columna_filtro["values"] = [""] + list(self.mapa_columnas)

    def limpiar_filtros(self):
        self.combo_usuario.set("")
        self.combo_columna_filtro.set("")
        self.entry_desde.delete(0, tk.END)
        self.entry_hasta.delete(0, tk.END)
        self.generar_reporte()

    def generar_reporte(self):
        try:
            desde = parsear_fecha(self.entry_desde.get())
            hasta = parsear_fecha(self.entry_hasta.get(), fin_del_dia=True)
        except ValueError as e:
            messagebox.showwarning("Fecha invalida", str(e))
            return

        uid = self.mapa_usuarios.get(self.combo_usuario.get())
        cid = self.mapa_columnas.get(self.combo_columna_filtro.get())

        try:
            filas = self.db.historial(usuario_id=uid, columna_id=cid,
                                      desde=desde, hasta=hasta, limite=5000)
        except Exception as e:
            messagebox.showerror("Error en el reporte", str(e))
            return

        self.tree.delete(*self.tree.get_children())
        for fila in filas:
            self.tree.insert("", tk.END,
                             values=tuple("" if v is None else v for v in fila))
        self.etiqueta_conteo.config(
            text=f"{len(filas)} registros, del mas reciente al mas antiguo")

    def exportar_csv(self):
        items = self.tree.get_children()
        if not items:
            messagebox.showwarning("Sin datos", "No hay nada que exportar.")
            return
        ruta = filedialog.asksaveasfilename(defaultextension=".csv",
                                            filetypes=[("Archivos CSV", "*.csv")])
        if not ruta:
            return
        # utf-8-sig para que Excel reconozca los acentos sin configurar nada.
        with open(ruta, "w", newline="", encoding="utf-8-sig") as f:
            escritor = csv.writer(f)
            escritor.writerow(self.COLUMNAS_REPORTE)
            for item in items:
                escritor.writerow(self.tree.item(item)["values"])
        messagebox.showinfo("Exportado", f"Reporte exportado a {ruta}")

    # -- pestana de estado ----------------------------------------------------

    def _tab_estado(self):
        tab = ttk.Frame(self.notebook, padding=10)
        self.notebook.add(tab, text="Estado")

        barra = ttk.Frame(tab)
        barra.pack(fill="x", pady=(0, 8))
        ttk.Button(barra, text="Actualizar", command=self.refrescar_estado).pack(side="left")
        ttk.Button(barra, text="Reanudar la tabla seleccionada",
                   command=self.reanudar_tabla).pack(side="left", padx=8)

        cols = ("tabla", "activa", "trigger", "columnas", "insert", "update", "delete")
        self.tree_estado = ttk.Treeview(tab, columns=cols, show="headings", height=16)
        for c in cols:
            self.tree_estado.heading(c, text=c)
            self.tree_estado.column(c, width=150 if c == "tabla" else 80, anchor="w")
        self.tree_estado.pack(fill="both", expand=True)

        ttk.Label(tab, foreground="#555", justify="left",
                  text=("Una tabla con activa en False y trigger en False esta suspendida:\n"
                        "conserva su configuracion y su bitacora, y puede reanudarse aqui.")
                  ).pack(anchor="w", pady=(8, 0))

        self.refrescar_estado()

    def refrescar_estado(self):
        try:
            filas = self.db.estado_auditoria()
        except Exception as e:
            messagebox.showerror("Error al leer el estado", str(e))
            return
        self.tree_estado.delete(*self.tree_estado.get_children())
        for fila in filas:
            self.tree_estado.insert("", tk.END, values=fila)

    def reanudar_tabla(self):
        sel = self.tree_estado.selection()
        if not sel:
            messagebox.showwarning("Faltan datos", "Elija una tabla de la lista.")
            return
        objeto = self.tree_estado.item(sel[0])["values"][0]
        esquema, tabla = str(objeto).split(".", 1)
        self._reportar(self.db.activar_tabla, esquema, tabla)


def main():
    try:
        db = AutoAuditDB(configuracion_conexion())
    except psycopg2.Error as e:
        print("No se pudo conectar a la base de datos:", e)
        return 1

    root = tk.Tk()
    AutoAuditApp(root, db)
    try:
        root.mainloop()
    finally:
        db.cerrar()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
