pipeline {
    agent any
    environment {
        BUILD_POD = sh(script: "kubectl get pods -o=jsonpath='{.items[0].metadata.name}' -n build-tool", returnStdout: true).trim()
        FRONTEND_POD = sh(script: "kubectl get pods -o=jsonpath='{.items[0].metadata.name}' -n starmf", returnStdout: true).trim()
        BACKEND_POD = sh(script: "kubectl get pods -o=jsonpath='{.items[0].metadata.name}' -n utility", returnStdout: true).trim()
        TAG = "${latestTag}"

    }

    stages {
        stage('Build') {
            steps {
                script {
                    // Checkout code including tags
                    git branch: 'master', url: 'https://git.starmfv2.remiges.tech/git/bse-starmfv2.web', credentialsId: '575cc78a-4998-4883-ae95-cacd618a5dee', fetchTags: true

                    // Retrieve the latest tag
                    def latestTag = sh(script: 'git describe --tags $(git rev-list --tags --max-count=1)', returnStdout: true).trim()
                    
                    echo "Latest tag is: $latestTag"
                    
                    //sh 'rm -rf *'
                    dir('bse-starmfv2.backend') {
                    checkout scm: [
                        $class: 'GitSCM',
                        userRemoteConfigs: [
                            [url: 'https://git.starmfv2.remiges.tech/git/bse-starmfv2.backend', credentialsId: '575cc78a-4998-4883-ae95-cacd618a5dee']
                        ],
                        branches: [
                            [name: "$latestTag"]
                        ]
                    ], poll: false
                    }
                    dir('bse-starmfv2.web') {
                    checkout scm: [
                        $class: 'GitSCM',
                        userRemoteConfigs: [
                            [url: 'https://git.starmfv2.remiges.tech/git/bse-starmfv2.web', credentialsId: '575cc78a-4998-4883-ae95-cacd618a5dee']
                        ],
                        branches: [
                            [name: "$latestTag"]
                        ]
                    ], poll: false
                    }
                    sh '''ls -al bse-starmfv2.backend
                          ls -al bse-starmfv2.web
                          tar cvzf bse-starmfv2.backend.tar.gz bse-starmfv2.backend
                          tar cvzf bse-starmfv2.web.tar.gz bse-starmfv2.web
                          ls -al
                          kubectl cp bse-starmfv2.backend.tar.gz build-tool/${BUILD_POD}:/var/starmf1
                          kubectl cp bse-starmfv2.web.tar.gz build-tool/${BUILD_POD}:/var/starmf1
                          kubectl exec -n build-tool ${BUILD_POD} -- /bin/bash -c "cd /var/starmf1 &&
                          tar xzvf bse-starmfv2.backend.tar.gz &&
                          tar xzvf bse-starmfv2.web.tar.gz &&
                          ./script.sh"
                          '''
                    sh '''kubectl exec -n build-tool ${BUILD_POD} -- /bin/bash -c "ls -al /var/starmf1 && 
                          cd /var/starmf1/bse-starmfv2.web && 
                          npm i --force && 
                          ng build --output-hashing=all --aot=true --optimization=true"
                          '''
                    sh '''kubectl exec -n build-tool ${BUILD_POD} -- /bin/bash -c "ls -al /var/starmf1 &&
                          cd /var/starmf1/bse-starmfv2.backend &&
                          make pg-migrate &&
                          make generate-sqlc-and-mock &&
                          go build"
                          '''
                }
            }
        }
        stage('QA') {
            steps {
                script {
                    sh '''kubectl exec -n build-tool ${BUILD_POD} -- /bin/bash -c "ls -al /var/starmf1 && 
                    cd /var/starmf1/bse-starmfv2.web &&
                    sonar-scanner -Dsonar.projectKey=test-web -Dsonar.sources=. -Dsonar.host.url=http://10.110.18.84:3050 -Dsonar.login=sqp_1f4c96614cca78ed3e8ac9d536f26119ca203d3f &&
                    cp -r src/assets dist/bse-app/ &&
                    cp src/favicon.ico dist/bse-app/ &&
                    ls -al dist/bse-app/ &&
                    cd /var/starmf1/bse-starmfv2.web/dist &&
                    tar cvzf starmfv2-web-${TAG}.tar.gz bse-app &&
                    cd /var/starmf1/bse-starmfv2.backend &&
                    sonar-scanner -Dsonar.projectKey=test-backend -Dsonar.sources=. -Dsonar.host.url=http://10.110.18.84:3050 -Dsonar.login=sqp_6841f65a725912c9e91f56212948e28ac464f881 "
                          '''
                }
            }
        }
        stage('Deploy') {
            steps {
                script {
                    sh '''kubectl cp build-tool/${BUILD_POD}:/var/starmf1/bse-starmfv2.web/dist/starmfv2-web-${TAG}.tar.gz starmfv2-web-${TAG}.tar.gz &&
                    kubectl cp starmfv2-web-${TAG}.tar.gz starmf/${FRONTEND_POD}:/home &&
                    kubectl cp build-tool/${BUILD_POD}:/var/starmf1/bse-starmfv2.backend/starmf starmf &&
                    kubectl cp build-tool/${BUILD_POD}:/var/starmf1/bse-starmfv2.backend/config_dev.json config_dev.json &&
                    kubectl cp build-tool/${BUILD_POD}:/var/starmf1/bse-starmfv2.backend/errortypes.yaml errortypes.yaml &&
                    kubectl cp starmf utility/${BACKEND_POD}:/home &&
                    kubectl cp errortypes.yaml utility/${BACKEND_POD}:/home &&
                    kubectl cp config_dev.json utility/${BACKEND_POD}:/home &&
                    kubectl exec -n utility ${BACKEND_POD} -- /bin/bash -c "cd /home && chmod a+x starmf"
                         '''
                }
            }
        }
   }
   post {
        success {
            echo 'Pipeline succeeded!!'
        }
        failure {
            echo 'Pipeline failed!'
        }
        unstable {
            echo 'Pipeline is unstable!'
        }
        aborted {
            echo 'Pipeline was aborted!'
        }
    }
}