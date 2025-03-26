package handlers

import (
	"encoding/json"
	"io"
)

func decodeJson(input io.ReadCloser, v any) error {
	// Can't use Echo's Bind method since it allows UnknownFields
	defer input.Close()
	decoder := json.NewDecoder(input)
	decoder.DisallowUnknownFields()
	return decoder.Decode(v)
}
