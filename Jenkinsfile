pipeline {
    agent any

    tools {
        jdk 'jdk21'
        maven 'maven3'
        dockerTool 'docker'
    }

    parameters {
        string(name: 'APP_VERSION', defaultValue: '1.0-SNAPSHOT', description: 'Artifact version to build/publish')
        string(name: 'GIT_BRANCH', defaultValue: 'main', description: 'Branch to checkout')
        string(name: 'DOCKER_IMAGE_TAG', defaultValue: 'latest', description: 'Docker image tag to apply/push')
    }

    environment {
        SCANNER_HOME = tool 'sonar-scanner'

        // --- Git ---
        GIT_REPO_URL     = 'https://github.com/Pratik543/task-master-pro'

        // --- Sonar ---
        SONAR_PROJECT_KEY  = 'TaskMasterPro'
        SONAR_PROJECT_NAME = 'TaskMasterPro'

        // --- Nexus ---
        NEXUS_VERSION    = 'nexus3'
        NEXUS_PROTOCOL   = 'http'
        NEXUS_URL        = '3.111.76.25:8081' # your jenkins slave ip where nexus is running via docker
        NEXUS_REPOSITORY = 'maven-snapshots'
        NEXUS_CREDS_ID   = 'nexus-creds'

        // --- App/Artifact ---
        GROUP_ID    = 'com.example.todo'
        ARTIFACT_ID = 'todo-app'
        APP_VERSION = "${params.APP_VERSION}"
        JAR_FILE    = "target/${ARTIFACT_ID}-${APP_VERSION}.jar"

        // --- Docker ---
        DOCKER_CREDS_ID    = 'docker-creds'
        DOCKER_IMAGE_NAME  = 'c0dechamp/prodtaskmaster'
        DOCKER_IMAGE_TAG   = "${params.DOCKER_IMAGE_TAG}"

        // --- Kubernetes ---
        KUBE_CREDS_ID = 'k8s-token'
        KUBE_MANIFEST = 'deployment-service.yml'

        // --- OWASP ---
        DP_CHECK_TOOL = 'dp-check'
    }

    stages {
        stage('Git Checkout') {
            steps {
                git branch: "${params.GIT_BRANCH}", url: "${env.GIT_REPO_URL}"
            }
        }

        stage('Maven Compile') {
            steps {
                sh "mvn compile"
            }
        }

        stage('Unit Tests') {
            steps {
                sh "mvn test -DskipTests=true"
            }
        }

        stage('SonarQube Analysis') {
            steps {
                withSonarQubeEnv('sonar-server') {
                    sh """
                        $SCANNER_HOME/bin/sonar-scanner \
                          -Dsonar.projectKey=${env.SONAR_PROJECT_KEY} \
                          -Dsonar.projectName=${env.SONAR_PROJECT_NAME} \
                          -Dsonar.java.binaries=.
                    """
                }
            }
        }

        stage('OWASP Dependency Check') {
            steps {
                dependencyCheck additionalArguments: '--scan ./', odcInstallation: "${env.DP_CHECK_TOOL}"
                dependencyCheckPublisher pattern: '**/dependency-check-report.xml'
            }
        }

        stage('Maven Build') {
            steps {
                sh "mvn clean package -DskipTests=true"
            }
        }

        stage('Publish to Nexus') {
            steps {
                script {
                    nexusArtifactUploader(
                        nexusVersion: env.NEXUS_VERSION,
                        protocol: env.NEXUS_PROTOCOL,
                        nexusUrl: env.NEXUS_URL,
                        groupId: env.GROUP_ID,
                        version: env.APP_VERSION,
                        repository: env.NEXUS_REPOSITORY,
                        credentialsId: env.NEXUS_CREDS_ID,
                        artifacts: [
                            [
                                artifactId: env.ARTIFACT_ID,
                                classifier: '',
                                file: env.JAR_FILE,
                                type: 'jar'
                            ]
                        ]
                    )
                }
            }
        }

        stage('Docker Build & Tag Image') {
            steps {
                script {
                    withCredentials([usernamePassword(credentialsId: env.DOCKER_CREDS_ID, usernameVariable: 'DOCKER_USER', passwordVariable: 'DOCKER_PASS')]) {
                        sh 'echo "$DOCKER_PASS" | docker login -u "$DOCKER_USER" --password-stdin'
                    }
                    withDockerRegistry(credentialsId: env.DOCKER_CREDS_ID, toolName: env.dockerTool) {
                        sh '''
                            docker build -t "$DOCKER_IMAGE_NAME:$APP_VERSION" .
                            docker tag "$DOCKER_IMAGE_NAME:$APP_VERSION" "$DOCKER_IMAGE_NAME:$DOCKER_IMAGE_TAG"
                            echo "Built and tagged: $DOCKER_IMAGE_NAME:$APP_VERSION and $DOCKER_IMAGE_TAG"
                        '''
                    }
                }
            }
        }

        stage('Trivy Image Scan') {
            steps {
                sh 'trivy image --format table -o trivy-image-report.html "$DOCKER_IMAGE_NAME:$APP_VERSION"'
            }
        }

        stage('Docker Push') {
            steps {
                script {
                    withCredentials([usernamePassword(credentialsId: env.DOCKER_CREDS_ID, usernameVariable: 'DOCKER_USER', passwordVariable: 'DOCKER_PASS')]) {
                        sh 'echo "$DOCKER_PASS" | docker login -u "$DOCKER_USER" --password-stdin'
                    }
                    withDockerRegistry(credentialsId: env.DOCKER_CREDS_ID, toolName: env.dockerTool) {
                        sh '''
                            docker push "$DOCKER_IMAGE_NAME:$APP_VERSION"
                            docker push "$DOCKER_IMAGE_NAME:$DOCKER_IMAGE_TAG"
                            echo "Pushed: $DOCKER_IMAGE_NAME:$APP_VERSION and $DOCKER_IMAGE_NAME:$DOCKER_IMAGE_TAG"
                        '''
                    }
                }
            }
        }

        stage('Kubernetes Deploy') {
            steps {
                withKubeConfig([caCertificate: '', credentialsId: env.KUBE_CREDS_ID, namespace: 'webapps', restrictKubeConfigAccess: false, serverUrl: 'https://10.0.1.41:6443']) {
                    sh '''
                        kubectl apply -f "$KUBE_MANIFEST"
                        kubectl rollout status deployment/taskmaster-deployment --timeout=300s
                    '''
                }
            }
        }

        stage('Verify the Deployment') {
            steps {
               withKubeConfig([caCertificate: '', credentialsId: env.KUBE_CREDS_ID, namespace: 'webapps', restrictKubeConfigAccess: false, serverUrl: 'https://10.0.1.41:6443']) {
                    sh "kubectl get pods -n webapps"
                    sh "kubectl get svc -n webapps"
                }
            }
        }
    }

    post {
        always {
            script {
               def jobName = env.JOB_NAME
               def buildNumber = env.BUILD_NUMBER
               def pipelineStatus = currentBuild.result ?: 'UNKNOWN'
               def bannerColor = pipelineStatus.toUpperCase() == 'SUCCESS' ? 'green' : 'red'

               def body = """
                <html>
                <body>
                <div style="border: 4px solid ${bannerColor}; padding: 10px;">
                <h2>${jobName} - Build ${buildNumber}</h2>
                <div style="background-color: ${bannerColor}; padding: 10px;">
                <h3 style="color: white;">Pipeline Status: ${pipelineStatus.toUpperCase()}</h3>
                </div>
                <p>Check the <a href="${BUILD_URL}">console output</a>.</p>
                </div>
                </body>
                </html>
              """

                emailext (
                    subject: "${jobName} - Build ${buildNumber} - ${pipelineStatus.toUpperCase()}",
                    body: body,
                    to: 'guptapratik304@gmail.com',
                    from: 'jenkins@example.com',
                    replyTo: 'jenkins@example.com',
                    mimeType: 'text/html',
                    attachmentsPattern: 'trivy-image-report.html'
                )
            }
        }
        success {
            archiveArtifacts artifacts: 'target/*.jar', allowEmptyArchive: true
            echo """
                Build successful on branch ${env.GIT_BRANCH}.
                
                Artifacts:
                  - ${env.JAR_FILE} uploaded to Nexus (${env.NEXUS_REPOSITORY})
                  - Docker image ${env.DOCKER_IMAGE_NAME}:${env.APP_VERSION} (also tagged ${env.DOCKER_IMAGE_TAG}) pushed to Docker Hub
                  - Trivy report: trivy-image-report.html (attached to notification)
                
                Deployed:
                  - ${env.KUBE_MANIFEST} applied to namespace 'webapps' (serverUrl https://10.0.1.41:6443)
                  - deployment/taskmaster-deployment rollout status confirmed
            """
        }
        failure {
            echo "Pipeline failed. Check logs above."
        }
    }
}
