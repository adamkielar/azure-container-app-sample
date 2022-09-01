// ========== //
// Parameters //
// ========== //
param location string = resourceGroup().location
param acrName string = 'acrhelloworld'
param envName string = 'hello-world-env'
param appName string = 'hello-world-app'
param logName string = 'hello-world-log'
param appIdentityName string = 'hello-world-id'
param scriptIdentityName string = 'hello-world-script-id'
param imageTag string = '1.23.1'

// ========== //
// Variables  //
// ========== //
var _resourceName =  uniqueString(resourceGroup().id)

// ============== //
// Log Analytics
// ============== //

resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2021-12-01-preview' = {
  name: logName
  location: location
}

// ============== //
// Azure Container Registry
// ============== //

resource demoACR 'Microsoft.ContainerRegistry/registries@2019-05-01' = {
  name: '${acrName}${_resourceName}'
  location: location
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: false
  }
}

// ============== //
// Deployment Script User-assigned Identity
// ============== //

resource scriptIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2018-11-30' = {
  name: scriptIdentityName
  location: location
}

// ============== //
// Assign Role for Deployment Script
// ============== //

resource contributorRole 'Microsoft.Authorization/roleAssignments@2020-08-01-preview' = {
  name: guid(demoACR.name, 'Contributor', scriptIdentity.id)
  scope: demoACR
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '8311e382-0749-4cb8-b61a-304f252e45ec')
    principalId: scriptIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// ============== //
// Import Image to ACR
// ============== //

resource importImage 'Microsoft.Resources/deploymentScripts@2020-10-01' = {
  name: 'acr-import-${demoACR.name}'
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${scriptIdentity.id}': {}
    }
  }
  kind: 'AzureCLI'
  properties: {
    azCliVersion: '2.38.0'
    timeout: 'PT5M'
    retentionInterval: 'P1D'
    environmentVariables: [
      {
        name: 'acrName'
        value: demoACR.name
      }
      {
        name: 'imageName'
        value: 'docker.io/library/nginx:${imageTag}'
      }
    ]
    scriptContent: 'az acr import --name $acrName --source $imageName --force'
  }
}

// ============== //
// Container App Environment
// ============== //

resource demoENV 'Microsoft.App/managedEnvironments@2022-01-01-preview' = {
  name: envName
  location: location
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalyticsWorkspace.properties.customerId
        sharedKey: logAnalyticsWorkspace.listKeys().primarySharedKey
      }
    }
  }
}

// ============== //
// User-assigned Identity For Container App
// ============== //

resource appIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2018-11-30' = {
  name: appIdentityName
  location: location
}

// ============== //
// Assign AcrPull Role to appIdentity
// ============== //

resource acrPullRole 'Microsoft.Authorization/roleAssignments@2020-08-01-preview' = {
  name: guid(demoACR.name, 'AcrPull', appIdentity.id)
  scope: demoACR
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
    principalId: appIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// ============== //
// Container App Resource
// ============== //

resource demoAPP 'Microsoft.App/containerApps@2022-03-01' = {
  name: appName
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${appIdentity.id}': {}
    }
  }
  properties: {
    configuration: {
      ingress: {
        external: true
        targetPort: 80
        allowInsecure: false
        traffic: [
          {
            latestRevision: true
            weight: 100
          }
        ]
      }
      registries: [
        {
          server: '${demoACR.name}.azurecr.io'
          identity: appIdentity.id
        }
      ]
    }
    managedEnvironmentId: demoENV.id
    template: {
      containers: [
        {
          name: appName
          image: '${demoACR.name}.azurecr.io/library/nginx:${imageTag}'
        }
      ]
    }
  }
}
