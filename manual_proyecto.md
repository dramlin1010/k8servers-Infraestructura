## Índice

1. [Descripción general del proyecto](#descripción-general-del-proyecto)
2. [Tecnologías utilizadas](#tecnologías-utilizadas)
3. [Instalación y despliegue](#instalación-y-despliegue)
    - [Requisitos previos](#requisitos-previos)
    - [Instalación paso a paso](#instalación-paso-a-paso)
    - [Ejecución y acceso](#ejecución-y-acceso)
4. [Capturas de pantalla y diagramas](#capturas-de-pantalla-y-diagramas)

---

## Descripción general del proyecto

**k8servers** es una plataforma de hosting web orientada a desarrolladores y creativos que desean desplegar y gestionar sus proyectos online de forma sencilla, segura y flexible.  
Permite a los usuarios registrar una cuenta, contratar un servicio de hosting, gestionar sus sitios web, subir archivos, consultar facturas y abrir tickets de soporte, todo desde un panel de usuario intuitivo.

El sistema está diseñado para ser escalable y automatizado, utilizando Kubernetes como orquestador de contenedores, cert-manager para la gestión automática de certificados TLS, y AWS EFS para el almacenamiento compartido de archivos.

---

## Tecnologías utilizadas

- **Kubernetes**: Orquestación de contenedores y despliegue de servicios.
- **Docker**: Contenedores para PHP-FPM, Nginx y otros servicios.
- **cert-manager**: Gestión automática de certificados TLS con Let's Encrypt.
- **AWS EFS**: Almacenamiento de archivos compartido entre pods.
- **MariaDB**: Base de datos relacional para la aplicación.
- **PHP**: Backend de la aplicación web.
- **Nginx**: Servidor web y proxy inverso.
- **Helm**: Despliegue de charts para servicios como ingress-nginx.
- **GitHub Actions**: CI/CD para despliegue automatizado.
- **AWS CLI**: Gestión de recursos AWS y backups automáticos.
- **Terraform**: (opcional) Para aprovisionamiento de infraestructura.
- **Bash**: Scripts de automatización y workers.

---

## Instalación y despliegue

### Requisitos previos

- Acceso a AWS (EFS, S3, IAM, Route53).
- Dominio propio configurado en Route53.
- Docker y kubectl instalados.
- Git y acceso al repositorio del proyecto.

### Instalación paso a paso

1. **Clonar el repositorio:**
    ```bash
    git clone https://github.com/tu_usuario/k8servers_web.git
    cd k8servers_web
    ```

2. **Configurar variables de entorno necesarias:**
    - AWS credentials (`TF_VAR_aws_access_key_id`, `TF_VAR_aws_secret_access_key`, etc.)
    - Variables de dominio y correo admin.

3. **Ejecutar el script de instalación principal:**
    ```bash
    sudo bash user-data.sh
    ```
    Este script instalará dependencias, configurará MariaDB, montará EFS, instalará K3s (Kubernetes), ingress-nginx, cert-manager, y desplegará la aplicación.

4. **Configurar backups automáticos a S3:**
    - El script crea un cron job para realizar backups diarios de la base de datos y archivos importantes.

5. **Desplegar el worker de aprovisionamiento:**
    - El worker se instala como un servicio systemd y se encarga de crear los recursos Kubernetes y usuarios SFTP para cada cliente.

### Ejecución y acceso

- Accede al panel de usuario desde el dominio configurado (ej: https://k8servers.es).
- El panel de administración está disponible para el usuario admin.
- Los clientes pueden gestionar sus sitios, archivos y tickets desde su panel personal.
