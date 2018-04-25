package main

import (
	"io/ioutil"
	"log"
	"os"

	"gopkg.in/yaml.v2"
)

type input struct {
	Path string
	Tags []struct {
		Name  string
		Value string
	}
	Multiline struct {
		Enabled   bool
		FirstLine string `yaml:"first_line"`
	}
	Parsers []string
}

type configuration struct {
	Inputs []input
}

func readFile(filename *string) (*[]byte, error) {
	if _, err := os.Stat(*filename); err != nil {
		return nil, err
	}

	data, err := ioutil.ReadFile(*filename)

	if err != nil {
		return nil, err
	}

	return &data, nil

}

func readConfig(config *string) *[]byte {
	source, err := readFile(config)
	if err != nil {
		log.Fatalf("error: %v", err)
	}

	return source
}

func parseConfig(data *[]byte) *configuration {
	var config configuration
	if err := yaml.Unmarshal(*data, &config); err != nil {
		log.Fatalf("error: %v", err)
	}

	return &config
}

func getConfig() *configuration {
	return parseConfig(readConfig(confFilePath))
}
