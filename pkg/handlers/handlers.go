package handlers

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"golang.org/x/oauth2/google"
	"k8s.io/apimachinery/pkg/labels"
	"k8s.io/client-go/rest"
	"net/http"

	"github.com/labstack/echo/v4"
	"sigs.k8s.io/controller-runtime/pkg/client"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	"github.com/konflux-ci/namespace-generator/pkg/api/v1alpha1"
)

const (
	ArgoCDNamespace = "argocd"
	Remote          = "remote"
)

type ClusterSecretConfig struct {
	ExecProviderConfig struct {
		APIVersion string   `json:"apiVersion"`
		Command    string   `json:"command"`
		Args       []string `json:"args"`
	} `json:"execProviderConfig,omitempty"`
	TLSClientConfig struct {
		Insecure bool   `json:"insecure"`
		CAData   string `json:"caData"`
	} `json:"tlsClientConfig"`
}

var defaultGCPScopes = []string{
	"https://www.googleapis.com/auth/cloud-platform",
	"https://www.googleapis.com/auth/userinfo.email",
}

type K8sClientFactory func(echo.Logger) (client.Reader, error)

type GetParamsHandler struct {
	k8sClientFactory K8sClientFactory
}

func NewGetParamsHandler(k8sClientFactory K8sClientFactory) *GetParamsHandler {
	return &GetParamsHandler{k8sClientFactory: k8sClientFactory}
}

// +kubebuilder:rbac:groups=tekton.dev,resources=pipelineruns,verbs=get;list;watch;create;update;patch
func (paramsHandler *GetParamsHandler) GetParams(ctx echo.Context) error {
	req := &v1alpha1.GenerateRequest{}
	err := decodeJson(ctx.Request().Body, req)

	if err != nil {
		ctx.Logger().Errorf("Failed to parse request body, %s", err)
		return ctx.NoContent(http.StatusBadRequest)
	}

	selector, err := metav1.LabelSelectorAsSelector(&req.Input.Parameters.LabelSelector)
	if err != nil {
		ctx.Logger().Errorf("Failed to parse label selector %s, %s", err)
		return ctx.NoContent(http.StatusBadRequest)
	}

	localClient, err := paramsHandler.k8sClientFactory(ctx.Logger())
	if err != nil {
		ctx.Logger().Errorf("Failed to get k8s client: %s", err)
		return ctx.NoContent(http.StatusInternalServerError)
	}

	nsList := &corev1.NamespaceList{}

	clusterName := req.Input.Parameters.ClusterName
	if clusterName == "" {
		ctx.Logger().Debug("No cluster name found in request. Searching for local cluster namespaces")
		err = getLocalNamespaces(ctx, localClient, nsList, selector)
	} else {
		ctx.Logger().Debug(fmt.Sprintf("Found secret name in request '%s'", clusterName))
		err = getRemoteClusterNamespaces(ctx, localClient, nsList, selector, req)
	}
	if err != nil {
		return ctx.NoContent(http.StatusInternalServerError)
	}

	generateResponse := &v1alpha1.GenerateResponse{}
	for _, namespace := range nsList.Items {
		generateResponse.Output.Parameters = append(
			generateResponse.Output.Parameters,
			v1alpha1.OutParameters{
				Namespace: namespace.Name,
			},
		)
	}

	ctx.Logger().Debugf("Cluster Name: '%s' - Response: %+v", clusterName, generateResponse)

	return ctx.JSON(http.StatusOK, generateResponse)
}

func getRemoteClusterNamespaces(ctx echo.Context, cl client.Reader, nsList *corev1.NamespaceList, selector labels.Selector, req *v1alpha1.GenerateRequest) error {
	secretName := req.Input.Parameters.ClusterName

	// Get the secret from the argocd namespace.
	secret := &corev1.Secret{}
	err := cl.Get(context.Background(), client.ObjectKey{Namespace: ArgoCDNamespace, Name: secretName}, secret)
	if err != nil {
		ctx.Logger().Errorf("Failed to get secret %s in namespace %s: %v", secretName, ArgoCDNamespace, err)
		return err
	}
	ctx.Logger().Debugf("Found secret %s", secretName)

	// Extract connection data from the secret.
	clusterEndpoint, ok := secret.Data["server"]
	if !ok {
		err := fmt.Errorf("secret %s missing 'server' key", secretName)
		ctx.Logger().Error(err.Error())
		return err
	}

	caBytes, ok := secret.Data["config"]
	if !ok {
		err := fmt.Errorf("secret %s missing 'config' key", secretName)
		ctx.Logger().Error(err.Error())
		return err
	}

	var configObj ClusterSecretConfig
	if err := json.Unmarshal(caBytes, &configObj); err != nil {
		ctx.Logger().Errorf("failed to unmarshal secret config: %v", err)
		return err
	}

	// Decode the inner CA data from base64.
	decodedCA, err := base64.StdEncoding.DecodeString(configObj.TLSClientConfig.CAData)
	if err != nil {
		ctx.Logger().Errorf("Failed to decode CA data: %v", err)
		return err
	}

	// Use the Google Cloud Workload Identity to get a token.
	// This code is exactly what argocd-k8s-auth uses.
	cred, err := google.FindDefaultCredentials(context.Background(), defaultGCPScopes...)
	if err != nil {
		ctx.Logger().Errorf("failed to get default credentials: %v", err)
		return err
	}
	t, err := cred.TokenSource.Token()
	if err != nil {
		ctx.Logger().Errorf("failed to get token: %v", err)
		return err
	}

	remoteCfg := &rest.Config{
		Host: string(clusterEndpoint),
		TLSClientConfig: rest.TLSClientConfig{
			CAData: decodedCA,
		},
		BearerToken: t.AccessToken,
	}

	// Create a remote Kubernetes client using controller-runtime.
	remoteClient, err := client.New(remoteCfg, client.Options{})
	if err != nil {
		ctx.Logger().Errorf("Failed to create remote client for cluster at %s: %v", string(clusterEndpoint), err)
		return err
	}

	// List namespaces from the remote cluster, filtered by the given label selector.
	err = remoteClient.List(context.Background(), nsList, &client.ListOptions{LabelSelector: selector})
	if err != nil {
		ctx.Logger().Errorf("Failed to list namespaces on remote cluster: %v with error: %v", string(clusterEndpoint), err)
		return err
	}

	return nil
}

func getLocalNamespaces(ctx echo.Context, cl client.Reader, nsList *corev1.NamespaceList, selector labels.Selector) error {
	err := cl.List(
		context.Background(),
		nsList,
		&client.ListOptions{LabelSelector: selector},
	)
	if err != nil {
		ctx.Logger().Errorf("Failed to list namespaces, %s", err)
	}

	return err
}
