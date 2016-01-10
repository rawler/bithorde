//
// server.cpp
// ~~~~~~~~~~
//
// Copyright (c) 2003-2012 Christopher M. Kohlhoff (chris at kohlhoff dot com)
//
// Distributed under the Boost Software License, Version 1.0. (See accompanying
// file LICENSE_1_0.txt or copy at http://www.boost.org/LICENSE_1_0.txt)
//

#include "server.hpp"
#include <boost/lexical_cast.hpp>

namespace http {
namespace server {

server::server(boost::asio::io_service& ioSvc, const std::string& address, const uint16_t& port, const http::server::RequestRouter& root) :
	io_service_(ioSvc),
	acceptor_(io_service_),
	connection_manager_(),
	new_connection_(),
	request_handler_(root)
{
	// Open the acceptor with the option to reuse the address (i.e. SO_REUSEADDR).
	boost::asio::ip::tcp::resolver resolver(io_service_);
	boost::asio::ip::tcp::resolver::query query(address, boost::lexical_cast<std::string>(port));
	boost::asio::ip::tcp::endpoint endpoint = *resolver.resolve(query);
	acceptor_.open(endpoint.protocol());
	acceptor_.set_option(boost::asio::ip::tcp::acceptor::reuse_address(true));
	acceptor_.bind(endpoint);
	acceptor_.listen();

	start_accept();
}

uint16_t server::port()
{
	return acceptor_.local_endpoint().port();
}

void server::start_accept()
{
	new_connection_.reset(new connection(io_service_, connection_manager_, request_handler_));
	acceptor_.async_accept(new_connection_->socket(), [=](const boost::system::error_code& ec) {
		handle_accept(ec);
	});
}

void server::handle_accept(const boost::system::error_code& ec)
{
	// Check whether the server was stopped by a signal before this completion
	// handler had a chance to run.
	if (!acceptor_.is_open()) {
		return;
	}

	if (!ec) {
		connection_manager_.start(new_connection_);
	}

	start_accept();
}

void server::handle_stop()
{
	// The server is stopped by cancelling all outstanding asynchronous
	// operations. Once all operations have finished the io_service::run() call
	// will exit.
	acceptor_.close();
	connection_manager_.stop_all();
}

} // namespace server
} // namespace http
