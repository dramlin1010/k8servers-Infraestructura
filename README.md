# k8server_infraestructura

## Descripción

**k8server_infraestructura** es el proyecto encargado de la infraestructura y automatización del despliegue de la plataforma de hosting web [k8servers](https://k8servers.es).  
Incluye scripts, manifiestos de Kubernetes, configuraciones de AWS y herramientas necesarias para levantar y mantener el entorno de producción y desarrollo de k8servers.

## Estructura del repositorio

- `script/user-data.sh` — Script principal de aprovisionamiento de nodos.
- `*.tf` — Configuración de Terraform para recursos AWS.
- `Otros Repos` - Este proyecto esta unido con otros repositorios los cuales han sido creados para poder hacer correr la infraestructura al 100%

## Tecnologías principales

- **Kubernetes** (K3s)
- **Docker**
- **AWS (EFS, S3, Route53)**
- **cert-manager**
- **Helm**
- **MariaDB**
- **Nginx**
- **Bash scripts**
- **GitHub Actions** (CI/CD)

## Uso básico

1. Clona este repositorio en tu nodo o entorno de administración:
    ```bash
    git clone https://github.com/tu_usuario/k8server_infraestructura.git
    cd k8server_infraestructura
    ```

2. Lee el archivo `manual_proyecto.md` para instrucciones detalladas de instalación y despliegue.

3. Ejecuta el script principal de aprovisionamiento:
    ```bash
    sudo bash user-data.sh
    ```

4. El sistema desplegará automáticamente los servicios base y configurará la infraestructura necesaria.

## Documentación

Consulta el archivo [`manual_proyecto.md`](./manual_proyecto.md) para una guía completa de instalación, despliegue y administración.

---

**Autor:**  
Daniel Ramírez Linares (dramlin1010)  
TFG - k8servers.es
