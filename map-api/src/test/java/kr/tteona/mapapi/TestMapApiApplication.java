package kr.tteona.mapapi;

import org.springframework.boot.SpringApplication;

public class TestMapApiApplication {

	public static void main(String[] args) {
		SpringApplication.from(MapApiApplication::main).with(TestcontainersConfiguration.class).run(args);
	}

}
